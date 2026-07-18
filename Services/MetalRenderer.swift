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
    private var _library: MTLLibrary?

    /// 鱼眼矫正 compute pipeline state
    private var fisheyePipeline: MTLComputePipelineState?

    /// 地平线防抖 render pipeline state
    private var stabilizePipeline: MTLRenderPipelineState?

    /// 纹理缓存（加速 CVPixelBuffer ↔ MTLTexture 转换）
    private var textureCache: CVMetalTextureCache?

    /// 中间 RGBA 纹理池（双缓冲，避免 GPU/CPU 竞争）
    private var correctedTextures: [MTLTexture] = []
    private var currentTextureIndex: Int = 0

    /// 当前输出纹理尺寸
    private var outputSize: CGSize = .zero

    // MARK: - 帧节流

    /// 信号量限制同时处理的最大帧数，防止 CPU 提交远超 GPU 处理速度
    /// 设为 3 允许最多 3 帧在 GPU 管线中，兼顾吞吐和延迟
    private let frameSemaphore = DispatchSemaphore(value: 3)

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

    /// GPU 帧处理完成回调（在后台队列调用）
    /// - Parameter texture: 处理后的 RGBA 纹理（仅当 stabilizeEnabled=false 时包含矫正结果；
    ///   防抖开启时，结果直接渲染到 MTKView，回调传 nil）
    var onFrameCompleted: ((MTLTexture?) -> Void)?

    // MARK: - 初始化

    /// 管线是否已编译完成
    private var pipelinesReady = false

    private var textureCacheCreated = false

    private var library: MTLLibrary { _library! }

    override init() {
        guard let d = MTLCreateSystemDefaultDevice(),
              let q = d.makeCommandQueue() else {
            self.device = MTLCreateSystemDefaultDevice()!
            self.commandQueue = (MTLCreateSystemDefaultDevice()?.makeCommandQueue())!
            super.init()
            return
        }
        self.device = d
        self.commandQueue = q
        super.init()
        // 在后台预编译 Metal 管线，避免首帧阻塞 frameQueue
        prewarmPipelines()
    }

    /// 在后台线程预编译 Metal shader 管线
    /// makeDefaultLibrary() + makeComputePipelineState() + makeRenderPipelineState()
    /// 在设备上可能耗时 100-500ms，绝对不能阻塞帧处理队列
    private func prewarmPipelines() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard self.ensureLibrary() else {
                print("❌ [MetalRenderer] 无法加载 Metal 库")
                return
            }
            // 触发库中所有函数的加载
            _ = self.library.functionNames
            // 编译管线
            self.setupPipelines()
            self.pipelinesReady = true
            print("✅ [MetalRenderer] Metal 管线预编译完成")
        }
    }

    private func ensureLibrary() -> Bool {
        if _library != nil { return true }
        _library = device.makeDefaultLibrary()
        return _library != nil
    }

    // MARK: - 着色器管线设置

    private func setupPipelines() {
        guard ensureLibrary() else { return }
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

    /// 处理一帧视频（异步，不阻塞调用线程）
    ///
    /// - Parameters:
    ///   - pixelBuffer: 输入帧（YUV 420v / NV12 格式）
    ///   - displayView: 显示目标 MTKView（可选，nil 时不绘制到屏幕）
    /// - Returns: 处理后的 RGBA 纹理（可用于录制编码）；管线未就绪时返回 nil
    func render(
        pixelBuffer: CVPixelBuffer,
        into displayView: MTKView? = nil
    ) -> MTLTexture? {
        // 管线尚未编译完成 → 跳过本帧处理（后台正在编译，不影响 UI）
        guard pipelinesReady else { return nil }

        // 帧节流: 等待前一帧 GPU 工作完成（最多允许 3 帧并行）
        frameSemaphore.wait()

        let targetView = displayView ?? self.displayView
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            frameSemaphore.signal()
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
            frameSemaphore.signal()
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
            frameSemaphore.signal()
            return nil
        }

        // --- 更新输出纹理池 ---
        let newSize = CGSize(width: width, height: height)
        if outputSize != newSize {
            outputSize = newSize
            correctedTextures = [
                makeOutputTexture(width: width, height: height),
                makeOutputTexture(width: width, height: height),
            ].compactMap { $0 }
            currentTextureIndex = 0
        }

        guard correctedTextures.count >= 2 else {
            frameSemaphore.signal()
            return nil
        }

        // 从纹理池中轮换使用，避免 GPU 还在写上一帧时 CPU 就覆盖
        let outTexture = correctedTextures[currentTextureIndex]
        currentTextureIndex = (currentTextureIndex + 1) % correctedTextures.count

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
        var didPresentDrawable = false

        if stabilizeEnabled, let pipeline = stabilizePipeline, let view = targetView {
            applyHorizonStabilize(
                commandBuffer: commandBuffer,
                pipeline: pipeline,
                sourceTexture: outTexture,
                into: view
            )
            didPresentDrawable = true
        }

        // --- GPU 完成回调 ---
        // 弱引用以避免循环引用
        let completedTexture: MTLTexture? = didPresentDrawable ? nil : outTexture
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.frameSemaphore.signal()
            self?.onFrameCompleted?(completedTexture)
        }

        // --- 提交命令（异步，不阻塞） ---
        commandBuffer.commit()

        return didPresentDrawable ? nil : outTexture
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
        if textureCache == nil {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
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
