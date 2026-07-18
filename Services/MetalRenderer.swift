import MetalKit
import CoreVideo

// MARK: - Metal 渲染器

/// Metal 渲染管线调度器
///
/// 核心职责:
/// 1. 管理 Metal 设备、命令队列、着色器库
/// 2. 将 CVPixelBuffer (YUV NV12) 转换为 Metal 纹理
/// 3. 调度鱼眼矫正 + 地平线防抖 compute/vertex shader
/// 4. 输出最终纹理供 MTKView 显示或 AVAssetWriter 写入
///
/// 管线流程:
///   Camera (NV12) → Metal Y+UV Textures
///     → [Fisheye Correction Compute Shader] → RGBA Texture
///     → [Horizon Stabilize Vertex/Fragment] → Display Texture
///
final class MetalRenderer: NSObject, ObservableObject {

    // MARK: - Metal 对象

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    /// 鱼眼矫正 compute pipeline state
    private var fisheyePipeline: MTLComputePipelineState?

    /// 地平线防抖 render pipeline state
    private var stabilizePipeline: MTLRenderPipelineState?

    /// 纹理缓存（加速 CVPixelBuffer ↔ MTLTexture 转换）
    private var textureCache: CVMetalTextureCache?

    /// 中间 RGBA 纹理（矫正后的结果）
    private var correctedTexture: MTLTexture?

    /// 当前输出纹理尺寸
    private var outputSize: CGSize = .zero

    // MARK: - 公开属性

    /// 当前畸变参数（为 nil 时跳过矫正）
    @Published var distortionParams: DistortionParams?

    /// 防抖参数
    @Published var stabilizeParams: StabilizeParams = .zero

    /// 是否启用鱼眼矫正
    @Published var fisheyeEnabled: Bool = true

    /// 显示目标（弱引用）
    weak var displayView: MTKView?

    /// 是否启用地平线防抖
    @Published var stabilizeEnabled: Bool = true

    // MARK: - 初始化

    private let metalAvailable: Bool

    override init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice(),
              let queue = metalDevice.makeCommandQueue(),
              let metalLibrary = metalDevice.makeDefaultLibrary() else {
            print("⚠️ [MetalRenderer] Metal 不可用，使用软件模式")
            self.device = MTLCreateSystemDefaultDevice()!
            self.commandQueue = (MTLCreateSystemDefaultDevice()?.makeCommandQueue())!
            self.library = (MTLCreateSystemDefaultDevice()?.makeDefaultLibrary())!
            self.metalAvailable = false
            super.init()
            return
        }
        self.device = metalDevice
        self.metalAvailable = true
        self.commandQueue = queue

        // --- 加载着色器库 ---
        // 在 Xcode 中需要将 .metal 文件添加到 Compile Sources
        guard let metalLibrary = metalDevice.makeDefaultLibrary() else {
            fatalError("❌ [MetalRenderer] 无法加载默认着色器库。请确保 .metal 文件已添加到 Target")
        }
        self.library = metalLibrary

        super.init()

        // --- 创建纹理缓存 ---
        CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &textureCache
        )

        // 着色器延迟到首次渲染时编译
    }

    // MARK: - 着色器管线设置

    private func setupPipelines() {
        // --- 鱼眼矫正 Compute Pipeline ---
        if let fisheyeFunction = library.makeFunction(name: "fisheyeCorrectYUVtoRGBA") {
            do {
                fisheyePipeline = try device.makeComputePipelineState(
                    function: fisheyeFunction
                )
                print("✅ [MetalRenderer] 鱼眼矫正 shader 已编译")
            } catch {
                print("❌ [MetalRenderer] 鱼眼矫正 shader 编译失败: \(error)")
            }
        }

        // --- 地平线防抖 Render Pipeline ---
        // 使用简单的顶点+片段着色器在全屏四边形上渲染
        let vertexFunc = library.makeFunction(name: "horizonStabilizeVertex")
        let fragmentFunc = library.makeFunction(name: "horizonStabilizeFragment")

        if let vertexFunc = vertexFunc, let fragmentFunc = fragmentFunc {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // 禁用深度测试（2D 渲染不需要）
            descriptor.depthAttachmentPixelFormat = .invalid

            do {
                stabilizePipeline = try device.makeRenderPipelineState(
                    descriptor: descriptor
                )
                print("✅ [MetalRenderer] 地平线防抖 shader 已编译")
            } catch {
                print("❌ [MetalRenderer] 地平线防抖 shader 编译失败: \(error)")
            }
        }
    }

    // MARK: - 主渲染入口

    /// 处理一帧视频
    ///
    /// - Parameters:
    ///   - pixelBuffer: 输入帧（YUV 420v / NV12 格式）
    ///   - displayView: 显示目标 MTKView（可选，nil 时不绘制到屏幕）
    /// - Returns: 处理后的 RGBA 纹理（可用于录制编码）
    private var pipelinesSetup = false

    func render(
        pixelBuffer: CVPixelBuffer,
        into displayView: MTKView? = nil
    ) -> MTLTexture? {
        if !pipelinesSetup { setupPipelines(); pipelinesSetup = true }
        let targetView = displayView ?? self.displayView
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        // --- 步骤 1: CVPixelBuffer → Metal 纹理 ---
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let textureY = makeTexture(
            from: pixelBuffer,
            planeIndex: 0,
            pixelFormat: .r8Unorm,
            width: width,
            height: height
        ) else {
            print("❌ [MetalRenderer] 无法创建 Y 纹理")
            return nil
        }

        guard let textureUV = makeTexture(
            from: pixelBuffer,
            planeIndex: 1,
            pixelFormat: .rg8Unorm,
            width: width / 2,   // UV 平面宽度是 Y 的一半 (4:2:0)
            height: height / 2
        ) else {
            print("❌ [MetalRenderer] 无法创建 UV 纹理")
            return nil
        }

        // --- 更新输出纹理 ---
        let newSize = CGSize(width: width, height: height)
        if outputSize != newSize {
            outputSize = newSize
            correctedTexture = makeOutputTexture(width: width, height: height)
        }

        guard let outTexture = correctedTexture else {
            return nil
        }

        // --- 步骤 2: 鱼眼矫正 (如果启用) ---
        if fisheyeEnabled, let pipeline = fisheyePipeline {
            applyFisheyeCorrection(
                commandBuffer: commandBuffer,
                pipeline: pipeline,
                textureY: textureY,
                textureUV: textureUV,
                outTexture: outTexture,
                width: width,
                height: height
            )
        }

        // --- 步骤 3: 地平线防抖 (如果启用) ---
        var finalTexture: MTLTexture = outTexture

        if stabilizeEnabled, let pipeline = stabilizePipeline, let view = targetView {
            applyHorizonStabilize(
                commandBuffer: commandBuffer,
                pipeline: pipeline,
                sourceTexture: outTexture,
                into: view
            )
            // 不返回纹理（直接渲染到 MTKView）
        }

        // --- 提交命令 ---
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return finalTexture
    }

    // MARK: - 鱼眼矫正

    private func applyFisheyeCorrection(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLComputePipelineState,
        textureY: MTLTexture,
        textureUV: MTLTexture,
        outTexture: MTLTexture,
        width: Int,
        height: Int
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(pipeline)

        // 绑定纹理
        encoder.setTexture(textureY, index: 0)
        encoder.setTexture(textureUV, index: 1)
        encoder.setTexture(outTexture, index: 2)

        // 传入畸变参数
        let params = distortionParams ?? DistortionParams.zero
        var metalParams = params.metalArray
        encoder.setBytes(&metalParams, length: MemoryLayout<Float>.size * 6, index: 0)

        // 计算线程组大小
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
    }

    // MARK: - 地平线防抖

    private func applyHorizonStabilize(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        sourceTexture: MTLTexture,
        into view: MTKView
    ) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
              ) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)

        // 传入防抖参数
        var params = stabilizeParams
        encoder.setVertexBytes(&params, length: MemoryLayout<StabilizeParams>.size, index: 0)

        // 绘制全屏四边形（顶点着色器生成 6 个顶点）
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
    }

    // MARK: - 纹理创建辅助方法

    /// 从 CVPixelBuffer 的指定平面创建 Metal 纹理
    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        guard let textureCache = textureCache else { return nil }

        var cvTextureOut: CVMetalTexture?

        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTextureOut
        )

        guard status == kCVReturnSuccess, let cvTexture = cvTextureOut else {
            return nil
        }

        return CVMetalTextureGetTexture(cvTexture)
    }

    /// 创建输出用的 RGBA 纹理
    private func makeOutputTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget]
        descriptor.storageMode = .private // GPU 专用，性能最优

        return device.makeTexture(descriptor: descriptor)
    }
}

// MARK: - 防抖参数结构体（Metal 侧）

/// 防抖参数，从 Swift 传入 Metal shader
/// 内存布局必须与 HorizonStabilize.metal 中的 StabilizeParams 完全一致
struct StabilizeParams {
    var roll: Float = 0.0
    var pitch: Float = 0.0
    var yaw: Float = 0.0
    var cropMargin: Float = 0.12     // 默认裁剪 12% 边缘
    var focalLength: Float = 500.0   // 虚拟焦距

    /// 零值（无防抖）
    static let zero = StabilizeParams()
}
