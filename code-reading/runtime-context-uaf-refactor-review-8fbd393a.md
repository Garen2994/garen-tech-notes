# Runtime HEAD 8fbd393a Context 防 UAF 重构审查

> 对象代码仓：`/home/garen2994/workspace/coderepo/runtime`  
> 审查提交：`8fbd393a context refactor to defeat UAF`  
> 父提交：`01a66380 【PR】: Ascend950 support aclmdlRITaskGetSeqId.`  
> 结论类型：代码阅读 / 风险审查 / 防 UAF 覆盖分析

## 1. 总结结论

`HEAD 8fbd393a` 已经为 Runtime `Context` 建立了一套比较清晰的防 UAF 框架：

- 引入 `ContextState` 表达 Context 生命周期；
- 引入 magic 校验，识别已失效 Context；
- 引入 `ContextInUse()` / `ContextOutUse()` 引用计数；
- 引入 `ContextAcquire` / `ContextProtect` RAII guard；
- destroy/reset 时先进入 `FINALIZING`，阻断新的 USER 访问；
- 等待已有 in-use 引用释放；
- explicit context 通过 `TryDeleteIfNeeded()` 延迟 delete；
- primary context reset 后对象可留在全局 set 中，但状态变为 `NOT_INITIALIZED`，资源已释放。

这套机制的设计方向是对的，但**当前提交还不能认为 Context 已经被全面保护**。

原因是：Runtime 中大量资源对象内部都保存或间接保存 `Context *`，例如 `Stream`、`Model`、`CaptureModel`、`Event`、`Notify`、`TaskInfo` 等。当前 HEAD 虽然已经适配了不少路径，但仍能看到多处直接从资源对象取裸 `Context *` 后解引用，且没有 `ContextAcquire` / `ContextProtect`。这些路径在并发 `rtCtxDestroy`、`rtDeviceReset`、`rtDeviceResetForce`、snapshot restore、ACL graph capture、异步错误处理等场景下仍可能触发 UAF 或访问已释放资源。

最终判断：

> **机制方向正确，但适配不完整；当前仍有漏点。不能说 Context 已经真的全面受到保护。**

---

## 2. 这次重构想解决什么问题

### 2.1 原始风险

旧代码中常见写法是：

```cpp
Context *ctx = stm->Context_();
ctx->SomeMethod();
```

或者：

```cpp
if (stm->Context_() != nullptr) {
    stm->Context_()->TaskGenCallback_();
}
```

这种写法的问题是：`Stream`、`Model`、`Event` 等资源对象只是保存了一个裸 `Context *`。如果另一个线程正在 destroy/reset 对应 Context，那么当前线程拿到的指针可能已经进入 teardown、资源已释放，甚至已经被 delete。

典型并发风险：

```text
线程 A：从 Stream 中拿到 Context *
线程 B：rtCtxDestroy(ctx) / rtDeviceResetForce(dev)
线程 B：Context 进入 FINALIZING，释放资源，甚至 delete
线程 A：继续 ctx->xxx()
结果：UAF / 访问已释放资源 / 状态错乱
```

### 2.2 这次重构的目标

这次重构试图把裸指针访问变成“先 acquire，再使用”：

```cpp
const ContextAcquire ctxGuard(rawCtx, ContextAccessMode::USER);
Context *ctx = ctxGuard.get();
if (!ctxGuard) {
    return ctxGuard.error();
}

// guard 生命周期内使用 ctx
ctx->SomeMethod();
```

只要所有使用点都遵守这个协议，就可以保证：

1. Context 已经失效时，新访问会失败；
2. Context 正在 destroy 时，USER 访问会被阻断；
3. 已经进入执行区的访问持有 in-use 引用；
4. destroy 会等待这些 in-use 引用释放；
5. explicit context 不会在 guard 持有期间被 delete。

---

## 3. 核心防护机制是否成立

### 3.1 `ContextState` 生命周期状态

源码位置：

- `src/runtime/core/inc/context/context.hpp:80-85`

```cpp
enum class ContextState : uint8_t {
    NOT_INITIALIZED = 0U,
    INITIALIZING = 1U,
    ACTIVE = 2U,
    FINALIZING = 3U,
    FINALIZED = 4U,
    DEINITIALIZING = 5U,
};
```

状态含义：

| 状态 | 含义 | USER 访问建议 |
|---|---|---|
| `NOT_INITIALIZED` | 未初始化；primary reset 后对象可能仍在 set 中但资源已释放 | 不允许 |
| `INITIALIZING` | 初始化中 | 通常不允许 |
| `ACTIVE` | 正常可用 | 允许 |
| `FINALIZING` | teardown 中 | USER 不允许，INTERNAL 视设计允许 |
| `FINALIZED` | teardown 完成 | 不允许 |
| `DEINITIALIZING` | delete / 析构阶段 | 不允许 |

这里最关键的是：**primary context reset 后对象不一定消失，但资源可能已经释放**。因此以后判断 Context 是否安全，不能只看指针是否非空，也不能只看它是否仍在全局 set 中。

---

### 3.2 `CheckContextIsValid` 是合法访问入口

源码位置：

- `src/runtime/core/src/context/context_manage.cc`

核心行为：

```cpp
bool ContextManage::CheckContextIsValid(Context *const curCtx, const bool inUseFlag,
    ContextAccessMode accessMode, rtError_t *errorCode)
```

它会检查：

1. `curCtx != nullptr`；
2. Context 是否仍被 Runtime 管理；
3. magic 是否有效；
4. 当前 `ContextState` 对 USER / INTERNAL 是否可访问；
5. 如果 `inUseFlag == true`，则调用 `ContextInUse()`。

也就是说，`CheckContextIsValid(ctx, true, ...)` 不只是校验，它还会拿一个 in-use 引用。

正确模式应该是：

```cpp
rtError_t err = RT_ERROR_NONE;
if (!ContextManage::CheckContextIsValid(ctx, true, ContextAccessMode::USER, &err)) {
    return err;
}
const ContextProtect protect(ctx, ContextProtect::RefMode::EXISTING_IN_USE_REF);

// safe use ctx
```

或者使用更高层封装：

```cpp
const ContextAcquire ctxGuard(rawCtx, ContextAccessMode::USER);
Context *ctx = ctxGuard.get();
if (!ctxGuard) {
    return ctxGuard.error();
}

// safe use ctx
```

---

### 3.3 `ContextAcquire` / `ContextProtect` 的 RAII 语义

源码位置：

- `src/runtime/core/inc/context/context_guard.hpp`
- `src/runtime/core/inc/context/context_protect.hpp`
- `src/runtime/core/src/context/context_protect.cc`

`ContextAcquire` 做两件事：

1. 调 `ContextManage::CheckContextIsValid(raw, true, mode, &err_)`；
2. 成功后构造 `ContextProtect(EXISTING_IN_USE_REF)`。

`ContextProtect` 析构时：

```cpp
(void)ctx_->ContextOutUse();
(void)ctx_->TryDeleteIfNeeded();
ctx_ = nullptr;
```

这意味着：

- acquire 成功后，Context in-use 计数加一；
- guard 退出作用域后，in-use 计数减一；
- 如果该 Context 已经被标记为待删除，最后一个 guard 释放时触发 `TryDeleteIfNeeded()`。

这个 RAII 模型是防 UAF 的关键。

---

### 3.4 destroy/reset 侧的阻断和等待

源码位置：

- `src/runtime/core/src/context/context.cc:1470-1485`
- `src/runtime/core/src/context/context.cc:1488-1507`
- `src/runtime/core/src/context/context.cc:1510-1528`

`TearDownIsCanExecute()` 会先把 `ACTIVE` 切到 `FINALIZING`：

```cpp
if (!TrySwitchState(ContextState::ACTIVE, ContextState::FINALIZING, "TearDownIsCanExecute")) {
    ...
    return false;
}
```

进入 `FINALIZING` 后，新的 USER 访问应该无法 acquire。

`WaitUntilInUseCount()` 会等待已有 in-use 引用下降：

```cpp
while (GetInUseCount() > expectCount) {
    ...
}
```

`TryDeleteIfNeeded()` 负责 explicit context 的延迟删除：

```cpp
if (GetCount() != 0U) {
    return false;
}

SetState(ContextState::DEINITIALIZING, "TryDeleteIfNeeded");
(void)ContextManage::RemoveContextFromSet(this);
delete this;
```

所以核心协议是闭环的：

```text
Context 使用方 acquire
        ↓
ContextInUse++
        ↓
destroy/reset 进入 FINALIZING，阻断新 USER acquire
        ↓
destroy/reset 等待已有 in-use 释放
        ↓
ContextProtect 析构 ContextOutUse--
        ↓
最后一个引用释放后 explicit context 才可能 delete
```

因此，**机制本身是成立的，问题主要在于是否所有使用点都正确接入了这个机制。**

---

## 4. 已经适配较好的方向

这次提交已经在不少地方加入了保护，方向是正确的。

常见适配方式包括：

```cpp
const ContextAcquire ctxGuard((stm == nullptr) ? nullptr : stm->Context_(), ContextAccessMode::USER);
Context * const curCtx = ctxGuard.get();
```

或者：

```cpp
Context *ctx = stm->Context_();
if (ContextManage::CheckContextIsValid(ctx, true, ContextAccessMode::INTERNAL, &err)) {
    const ContextProtect guard(ctx, ContextProtect::RefMode::EXISTING_IN_USE_REF);
    ...
}
```

从抽查结果看，以下方向已经有明显改动：

- `Stream` 部分方法开始使用 `AcquireContext()`；
- `Event` / `Notify` / `IPC Event` 多数核心路径加入了 guard；
- `engine` / `task recycle` 一些从 stream 拿 context 的路径已经补了 `CheckContextIsValid + ContextProtect`；
- `CaptureModel` / `Model` 部分函数已经补了 `ContextAcquire`；
- primary context reset 行为和状态过滤开始被测试覆盖。

这些改动说明重构方向不是局部 hack，而是试图建立统一生命周期协议。

---

## 5. 明确漏点与风险分析

下面是本次审查确认的主要遗漏点。

---

### 5.1 高危：`memcpy_stars.cc` 仍直接裸用 `stm->Context_()`

文件：

- `src/runtime/core/src/launch/memcpy_stars.cc`

#### 位置 1

`src/runtime/core/src/launch/memcpy_stars.cc:104`

```cpp
callback = (stm->Context_() == nullptr) ? nullptr : stm->Context_()->TaskGenCallback_();
error = dev->SubmitTask(cpyAsyncTask, callback);
```

#### 位置 2

`src/runtime/core/src/launch/memcpy_stars.cc:140`

```cpp
callback = (stm->Context_() == nullptr) ? nullptr : stm->Context_()->TaskGenCallback_();
error = stm->Device_()->SubmitTask(taskAsync2d, callback);
```

#### 问题

这里有两个问题。

第一，存在 TOCTOU：

```cpp
stm->Context_() == nullptr
```

和：

```cpp
stm->Context_()->TaskGenCallback_()
```

是两次读取。第一次非空，不代表第二次仍然有效。

第二，没有 acquire：

- 没有 `ContextAcquire`；
- 没有 `ContextManage::CheckContextIsValid(..., true)`；
- 没有 `ContextProtect`。

如果另一个线程正在 destroy/reset stream 所属 context，这里可能直接解引用已经进入 teardown 或已释放的 Context。

#### 建议修复

如果该路径允许 context 无效时 callback 为空：

```cpp
rtTaskGenCallback callback = nullptr;
const ContextAcquire ctxGuard((stm == nullptr) ? nullptr : stm->Context_(), ContextAccessMode::USER);
Context * const ctx = ctxGuard.get();
if (ctxGuard) {
    callback = ctx->TaskGenCallback_();
}
```

如果该路径要求 stream context 必须有效，则应该直接返回错误：

```cpp
const ContextAcquire ctxGuard(stm->Context_(), ContextAccessMode::USER);
Context * const ctx = ctxGuard.get();
COND_RETURN_ERROR_MSG_INNER(!ctxGuard, ctxGuard.error(),
    "memcpy async failed because stream context is invalid, stream_id=%u.", stm->Id_());

callback = ctx->TaskGenCallback_();
```

---

### 5.2 高危：`stream_capture.cc` 仍直接从 Stream 裸取 Context

文件：

- `src/runtime/feature/aclgraph/stream_capture.cc`

#### 位置 1

`src/runtime/feature/aclgraph/stream_capture.cc:31-35`

```cpp
rtError_t Stream::AllocCascadeCaptureStream(Stream *&newCaptureStream, const Stream * const curCaptureStream)
{
    Context * const ctx = Context_();
    const rtError_t error = ctx->AllocCascadeCaptureStream(this, curCaptureStream->Model_(),
                                                     &newCaptureStream);
```

这里不仅没有 acquire，甚至没有空指针检查。

#### 位置 2

`src/runtime/feature/aclgraph/stream_capture.cc:91-102`

```cpp
Context * const ctx = Context_();
if (ctx == nullptr) {
    ...
    return RT_ERROR_CONTEXT_NULL;
}
rtError_t error = AllocCascadeCaptureStream(newCaptureStream, curCaptureStream);
...
if (error != RT_ERROR_NONE) {
    ctx->FreeCascadeCaptureStream(newCaptureStream);
```

虽然这里检查了 `ctx == nullptr`，但这只是空指针检查，不是生命周期保护。检查之后到 `ctx->FreeCascadeCaptureStream()` 之间，context 仍可能进入 `FINALIZING` 或被释放资源。

#### 风险

ACL graph capture 相关路径通常会长期持有 `Stream *` / `Model *` / `CaptureModel *`。如果 context destroy/reset 与 capture task 分配、级联 capture stream 创建并发，这里存在 UAF 风险。

#### 建议修复

在入口 acquire：

```cpp
rtError_t Stream::AllocCascadeCaptureStream(Stream *&newCaptureStream, const Stream * const curCaptureStream)
{
    const ContextAcquire ctxGuard(Context_(), ContextAccessMode::USER);
    Context * const ctx = ctxGuard.get();
    COND_RETURN_ERROR_MSG_INNER(!ctxGuard, ctxGuard.error(),
        "alloc cascade capture stream failed because context is invalid, stream_id=%u.", Id_());

    const rtError_t error = ctx->AllocCascadeCaptureStream(this, curCaptureStream->Model_(), &newCaptureStream);
    ...
}
```

`AllocCaptureTaskWithoutLock()` 中需要覆盖到 `ctx->FreeCascadeCaptureStream(newCaptureStream)` 的使用区间。

---

### 5.3 高危：`Model::ReBuild` 仍裸用 `context_`

文件：

- `src/runtime/feature/model/model_rebuild.cc`

位置：

`src/runtime/feature/model/model_rebuild.cc:203`

```cpp
if (context_->Device_()->IsSupportFeature(RtOptionalFeatureType::RT_FEATURE_TASK_ALLOC_FROM_STREAM_POOL)) {
    error = ModelLoadCompleteByStream(this);
} else {
    error = LoadCompleteByStream();
}
```

#### 问题

`Model` 内部保存 `context_`。这次重构已经在 `model_rebuild.cc` 中的部分函数里加入了 `ContextAcquire`，但是 `ReBuild()` 这里仍然直接使用：

```cpp
context_->Device_()
```

即使 `ReSetup()`、`ResetForRestore()`、`SinkSqTasksRestore()` 等子函数内部各自有 guard，也无法保护 `ReBuild()` 自己在 line 203 的裸访问。

#### 风险

`ReBuild()` 属于 snapshot/model restore 关键路径。如果 restore 与 context reset/destroy 并发，`context_` 可能已经不再 ACTIVE，甚至内部 device/resource 已释放。

#### 建议修复

建议在 `ReBuild()` 函数开始就持有覆盖整个 rebuild 过程的 guard：

```cpp
rtError_t Model::ReBuild()
{
    const ContextAcquire ctxGuard(context_, ContextAccessMode::USER);
    Context * const ctx = ctxGuard.get();
    COND_RETURN_ERROR_MSG_INNER(!ctxGuard, ctxGuard.error(),
        "rebuild model failed because context is invalid, model_id=%u.", id_);

    ...

    if (ctx->Device_()->IsSupportFeature(RtOptionalFeatureType::RT_FEATURE_TASK_ALLOC_FROM_STREAM_POOL)) {
        error = ModelLoadCompleteByStream(this);
    } else {
        error = LoadCompleteByStream();
    }

    ...
}
```

是否用 USER 还是 INTERNAL 取决于 restore 路径设计。如果 snapshot restore 是 Runtime 内部恢复流程，可能应该用 `ContextAccessMode::INTERNAL`，但必须显式说明语义。

---

### 5.4 中高危：snapshot restore 遍历 Context set 时没有 acquire

文件：

- `src/runtime/feature/snapshot/snapshot_process_helper.cc`

#### 位置 1：pre-process backup

`src/runtime/feature/snapshot/snapshot_process_helper.cc:23-30`

```cpp
const ReadProtect wp(&(ctxMan.GetSetRwLock()));
for (Context *const ctx : ctxMan.GetSetObj()) {
    // Primary contexts stay in the global set after reset, but their resources have been released.
    if (ctx->GetState() != ContextState::ACTIVE) {
        continue;
    }
    ret = ctx->Synchronize(-1);
```

这里只做了 `ACTIVE` 状态过滤，没有 acquire。

`ReadProtect` 保护的是 set 结构遍历，不等价于 Context 生命周期保护。它不能保证：

- `ctx` 不会马上进入 `FINALIZING`；
- `ctx` 内部资源不会被 reset/release；
- `ctx` 不会在遍历后被延迟 delete。

#### 位置 2：resource restore

`src/runtime/feature/snapshot/snapshot_process_helper.cc:59-66`

```cpp
const ReadProtect wp(&(ctxMan.GetSetRwLock()));
// 重新申请所有ctx上的stream id/event id/notify id
for (Context *const ctx : ctxMan.GetSetObj()) {
    ret = ctx->StreamsTaskClean();
    ERROR_RETURN(ret, "clean stream, ret=%#x.", ret);
    ret = ctx->StreamsRestore();
    ERROR_RETURN(ret, "Realloc stream id failed, ret=%#x.", ret);
}
```

这里甚至没有像 backup 阶段那样过滤 `ContextState::ACTIVE`。

这和前面的注释存在冲突：既然 primary context reset 后仍可能留在 global set，但资源已经释放，那么这里直接遍历所有 Context 并调用 `StreamsTaskClean()` / `StreamsRestore()` 就可能访问已释放资源。

#### 建议修复

至少应改为：

```cpp
for (Context *const rawCtx : ctxMan.GetSetObj()) {
    const ContextAcquire ctxGuard(rawCtx, ContextAccessMode::INTERNAL);
    Context * const ctx = ctxGuard.get();
    if (!ctxGuard) {
        continue;
    }
    if (ctx->GetState() != ContextState::ACTIVE) {
        continue;
    }
    ...
}
```

如果 snapshot restore 设计上必须处理 inactive primary context，则需要单独分支，而不是直接对所有 Context 调 stream restore。

---

### 5.5 中危：`GetErrorVerbose` 通过 primary Context 裸指针直接解引用

#### 普通实现

文件：

- `src/runtime/core/src/api_impl/api_impl.cc`

位置：

`src/runtime/core/src/api_impl/api_impl.cc:8775-8788`

```cpp
Context * const ctx = Runtime::Instance()->GetPriCtxByDeviceId(deviceId, tsId);
if (ctx == nullptr) {
    errorInfo->hasDetail = 0U;
    errorInfo->tryRepair = 0U;
    errorInfo->errorType = RT_NO_ERROR;
    RT_LOG(RT_LOG_DEBUG, "Device[%u] has no fault.", deviceId);
    return RT_ERROR_NONE;
}
Device * const dev = ctx->Device_();
```

#### David 实现

文件：

- `src/runtime/core/src/api_impl/api_impl_david.cc`

位置：

`src/runtime/core/src/api_impl/api_impl_david.cc:1912-1924`

```cpp
Context * const ctx = Runtime::Instance()->GetPriCtxByDeviceId(deviceId, tsId);
COND_RETURN_WARN(ctx == nullptr, RT_ERROR_NONE, "Device[%u] has no fault.", deviceId);
Device * const dev = ctx->Device_();
COND_RETURN_WARN(dev == nullptr, RT_ERROR_NONE, "Device[%u] has no fault.", deviceId);

rtError_t error = RT_ERROR_NONE;
const DeviceFaultType faultType = dev->GetDeviceFaultType();
```

#### 问题

`GetPriCtxByDeviceId()` 返回的是裸 `Context *`。primary context 这次重构后有一个重要变化：

- primary reset 后 Context 对象可能仍然存在；
- 但资源可能已经释放；
- 状态可能是 `NOT_INITIALIZED`；
- `Device_()` 可能为空或处于释放后状态。

因此不能直接信任返回值。

#### 建议修复

```cpp
Context * const rawCtx = Runtime::Instance()->GetPriCtxByDeviceId(deviceId, tsId);
const ContextAcquire ctxGuard(rawCtx, ContextAccessMode::USER);
Context * const ctx = ctxGuard.get();
if (!ctxGuard) {
    errorInfo->hasDetail = 0U;
    errorInfo->tryRepair = 0U;
    errorInfo->errorType = RT_NO_ERROR;
    return RT_ERROR_NONE;
}

Device * const dev = ctx->Device_();
```

如果 `GetErrorVerbose` 属于内部错误恢复路径，可以考虑 `ContextAccessMode::INTERNAL`，但需要明确允许读取 `FINALIZING` 状态下的错误信息。

---

### 5.6 中高危：`device_error_core_proc.cc` 异步错误处理路径裸用 stream context

文件：

- `src/runtime/core/src/device/device_error_core_proc.cc`

位置：

`src/runtime/core/src/device/device_error_core_proc.cc:561-567`

```cpp
static void MteErrorProc(const TaskInfo * const errTaskPtr, const Device * const dev, const int32_t errorCode, bool &isMteError)
{
    if ((errTaskPtr->stream != nullptr) && (errTaskPtr->stream->Context_() != nullptr) &&
        (errTaskPtr->stream->Device_() != nullptr) && (errorCode == RT_ERROR_DEVICE_MEM_ERROR)) {
        (RtPtrToUnConstPtr<TaskInfo *>(errTaskPtr))->stream->SetAbortStatus(errorCode);
        (RtPtrToUnConstPtr<TaskInfo *>(errTaskPtr))->stream->Context_()->SetFailureError(errorCode);
        (RtPtrToUnConstPtr<TaskInfo *>(errTaskPtr))->stream->Device_()->SetDeviceStatus(errorCode);
    }
```

#### 问题

这里同样是 TOCTOU：

```cpp
errTaskPtr->stream->Context_() != nullptr
```

和：

```cpp
errTaskPtr->stream->Context_()->SetFailureError(errorCode)
```

之间没有任何生命周期保护。

错误处理路径通常是异步触发，和 context teardown/reset 并发的概率并不低，因此不能简单认为安全。

#### 建议修复

```cpp
Stream * const stream = errTaskPtr->stream;
NULL_PTR_RETURN_DIRECTLY(stream);

const ContextAcquire ctxGuard(stream->Context_(), ContextAccessMode::INTERNAL);
Context * const ctx = ctxGuard.get();
if (ctxGuard && (stream->Device_() != nullptr) && (errorCode == RT_ERROR_DEVICE_MEM_ERROR)) {
    stream->SetAbortStatus(errorCode);
    ctx->SetFailureError(errorCode);
    stream->Device_()->SetDeviceStatus(errorCode);
}
```

这里更可能应该用 `INTERNAL`，因为设备错误处理属于 runtime 内部处理流。

---

## 6. 需要继续确认的裸比较路径

本次扫描还发现大量类似代码：

```cpp
COND_RETURN_AND_MSG_INVALID_CONTEXT(stm->Context_() != curCtx, RT_ERROR_STREAM_CONTEXT, ...)
```

这些路径广泛存在于：

- `src/runtime/core/src/api_impl/api_impl.cc`
- `src/runtime/core/src/api_impl/api_impl_david.cc`
- `src/runtime/feature/aclgraph/v100/api_impl_aclgraph.cc`
- `src/runtime/feature/model/model.cc`

这类代码不一定都是 UAF，因为它通常只是比较指针值，没有解引用 `stm->Context_()`。

但是它依赖两个前提：

1. `stm` 这个句柄对象本身仍有效；
2. 读取 `stm->context_` 与 stream destroy/context destroy 不会并发，或者外层已经有 stream 生命周期保护。

如果这两个前提不成立，单纯保护 `curCtx` 仍然不够。

建议后续审查时按如下规则判断：

- 只是比较 `stm->Context_() != curCtx`：标为需要确认；
- 比较后马上调用 `curCtx->xxx(stm)`，且 `curCtx` 已经有 guard：风险较低；
- 比较后又在深层函数里重新 `stm->Context_()->xxx()`：必须补 guard；
- 传入的 `stm` 可能跨线程 destroy：还需要 stream 句柄生命周期保护，单靠 Context guard 不够。

---

## 7. 测试覆盖缺口

这次提交新增/调整了不少 UT，已经覆盖了一些有价值的场景：

- destroyed context handle 被拒绝；
- magic invalid 检测；
- `FINALIZING` 下 USER/INTERNAL 访问差异；
- thread ref count；
- primary context reset 后对象仍 tracked；
- primary refcount release；
- force reset；
- explicit context 不被普通 device reset 销毁；
- 部分 stream 空 context 行为。

但这些还不足以证明防 UAF 完整。

### 7.1 缺少真实并发 destroy vs use 测试

需要补充：

```text
线程 A：持续使用 stream/event/model API
线程 B：调用 rtCtxDestroy(ctx) 或 rtDeviceResetForce(dev)
期望：不崩溃；API 返回 RT_ERROR_CONTEXT_DEL / RT_ERROR_CONTEXT_NULL；destroy 等待或延迟 delete
```

重点覆盖：

- memcpy async；
- stream capture；
- model rebuild；
- event record/synchronize；
- notify；
- task recycle / error proc。

### 7.2 缺少 `ContextAcquire` 直接单测

建议直接测试：

- `ACTIVE + USER` acquire 成功；
- `FINALIZING + USER` acquire 失败；
- `FINALIZING + INTERNAL` acquire 行为符合设计；
- invalid magic acquire 失败；
- guard 析构后 in-use 计数恢复。

### 7.3 缺少延迟删除测试

应该验证：

1. 创建 explicit context；
2. 手动或通过 `ContextAcquire` 持有 in-use；
3. 另一路调用 `rtCtxDestroy(ctx)`；
4. guard 未释放时 context 不应 delete；
5. guard 释放后 `TryDeleteIfNeeded()` 才真正 remove + delete。

### 7.4 缺少资源对象持旧 Context 指针的回归测试

需要构造：

- `Stream::context_` 指向已经 destroy / FINALIZING 的 context；
- `Model::context_` 指向已经 reset 的 primary context；
- snapshot restore 遍历到 `NOT_INITIALIZED` primary context；
- `TaskInfo->stream->Context_()` 在错误处理路径中遇到 reset/destroy。

这些测试最能证明“资源对象里保存的 context 指针不会导致 UAF”。

---

## 8. 建议修复优先级

### P0：明确裸解引用，建议立即修

| 文件 | 位置 | 问题 |
|---|---:|---|
| `src/runtime/core/src/launch/memcpy_stars.cc` | 104 | `stm->Context_()->TaskGenCallback_()` 无 guard |
| `src/runtime/core/src/launch/memcpy_stars.cc` | 140 | `stm->Context_()->TaskGenCallback_()` 无 guard |
| `src/runtime/feature/aclgraph/stream_capture.cc` | 33-35 | `ctx->AllocCascadeCaptureStream()` 无 guard |
| `src/runtime/feature/aclgraph/stream_capture.cc` | 91-102 | `ctx->FreeCascadeCaptureStream()` 无 guard |
| `src/runtime/feature/model/model_rebuild.cc` | 203 | `context_->Device_()` 无 guard |
| `src/runtime/core/src/device/device_error_core_proc.cc` | 563-567 | `stream->Context_()->SetFailureError()` 无 guard |

### P1：应修或需要更高层锁证明

| 文件 | 位置 | 问题 |
|---|---:|---|
| `src/runtime/feature/snapshot/snapshot_process_helper.cc` | 24-30 | 遍历 context set 后直接 `ctx->Synchronize()` |
| `src/runtime/feature/snapshot/snapshot_process_helper.cc` | 61-65 | 对所有 ctx 直接 `StreamsTaskClean/StreamsRestore`，没有 ACTIVE 过滤 |
| `src/runtime/core/src/api_impl/api_impl.cc` | 8779-8788 | primary ctx 裸指针直接 `ctx->Device_()` |
| `src/runtime/core/src/api_impl/api_impl_david.cc` | 1918-1924 | primary ctx 裸指针直接 `ctx->Device_()` |

### P2：建立长期代码规范

建议形成统一规则：

#### 规则 1：禁止链式裸解引用

禁止新增：

```cpp
stm->Context_()->xxx();
model->Context_()->xxx();
context_->Device_()->xxx();
```

除非函数注释明确说明“调用者已经持有 ContextAcquire，并且该函数只在 guard 生命周期内调用”。

#### 规则 2：资源对象内部使用 context 必须 acquire

凡是 `Stream` / `Model` / `Event` / `Notify` / `CaptureModel` 内部通过成员拿 context，默认都应写成：

```cpp
const ContextAcquire ctxGuard(context_, mode);
Context * const ctx = ctxGuard.get();
```

#### 规则 3：set 锁不是生命周期保护

这种代码不够：

```cpp
const ReadProtect rp(&ctxSetLock);
for (Context *ctx : set) {
    ctx->xxx();
}
```

需要：

```cpp
const ContextAcquire ctxGuard(ctx, ContextAccessMode::INTERNAL);
```

#### 规则 4：primary context 裸指针也要视为弱引用

`GetPriCtxByDeviceId()` 返回的 `Context *` 不应直接解引用。primary context reset 后对象可能还在，但资源可能已经释放。

---

## 9. 推荐 grep 审查清单

后续继续扫漏时，可以优先搜索这些模式：

```bash
# 链式裸用 Context
rg 'Context_\(\)->|context_->|ctx_->' src/runtime

# 从 stream/model/event 中取 context 后使用
rg 'Context \*.*Context_\(|Context\*.*Context_\(' src/runtime

# primary context 裸指针
rg 'GetPriCtxByDeviceId' src/runtime

# 全局 set 遍历后直接 ctx->
rg 'GetSetObj\(\)|for \(Context \*.*ctx' src/runtime

# 已有保护点，用于对照
rg 'ContextAcquire|ContextProtect|CheckContextIsValid' src/runtime
```

人工判断时重点看：

1. 是否解引用了 `Context *`；
2. 解引用前是否 acquire；
3. acquire guard 生命周期是否覆盖整个使用区间；
4. 使用的是 USER 还是 INTERNAL；
5. 是否只做了空指针检查或状态检查，但没有 in-use 引用；
6. 是否存在两次读取 `Context_()` 的 TOCTOU；
7. 是否依赖 set read lock，但没有 context in-use 引用。

---

## 10. 最终结论

`8fbd393a` 这次 context 防 UAF 重构已经完成了最关键的基础设施：状态机、magic、in-use 引用、RAII guard、destroy 阻断和延迟删除。这说明整体方向是正确的。

但是，Runtime 的 context 使用面太广，尤其是资源对象里保存的裸 `Context *` 太多。当前 HEAD 仍存在多个明确裸解引用点：

- memcpy submit callback；
- ACL graph stream capture；
- model rebuild；
- snapshot restore；
- error verbose；
- device error proc。

这些路径没有完整接入 `ContextAcquire` / `ContextProtect`，因此仍可能在并发 destroy/reset 或资源恢复场景下访问失效 Context。

最终判断：

> **当前 HEAD 不能认为 Context 已经完全受到保护。它已经有了防 UAF 框架，但资源对象相关路径仍需继续补齐 guard，并补充并发 destroy-vs-use 回归测试。**
