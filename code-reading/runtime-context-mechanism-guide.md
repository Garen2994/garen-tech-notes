# Runtime Context 机制导读

本文是 PR 1680 context 防 UAF 重构的机制导读。它不重复代码量统计，而是回答一个更核心的问题：

> Runtime 里 `Context` 到底是什么？它在各个重要接口里负责什么？为什么这次防 UAF 重构会影响 stream、event、notify、model、launch、task、device reset 等路径？

分析对象：

- PR: https://gitcode.com/cann/runtime/pull/1680
- 本地 commit: `7e71a71fa2f7f3ea374cd98b0bbfc610e162d4bb`
- parent: `ca804b2f4db75ad5f0d56c846cb5f74a03c37bc4`

关联统计文档：

- `.local/pr-1680-context-uaf-analysis.md`

## 1. 先建立一个心智模型

`Context` 可以理解成 Runtime 里“某个设备上的一套运行环境”。它不是一个普通句柄，也不是只保存 device id 的轻量对象。它是很多 Runtime 资源的归属中心。

它至少承担这些职责：

- 挂着 `Device *`，所以能找到驱动、SQ/CQ、task factory、默认流、primary stream、ctrl stream。
- 管理 stream/model/event/notify/capture model 等资源对象的归属关系。
- 保存任务生成回调 `TaskGenCallback_()`，很多 task submit 要从 context 取 callback。
- 保存 context 级错误状态和失败模式，`CheckStatus()` 会把 device fault、context failure、stream failure 转成 API 返回。
- 参与 teardown/reset，决定用户路径还能不能继续访问，内部清理路径还能不能继续提交任务。
- 作为防 UAF 的生命周期仲裁者：对象可能已经进入销毁，但只要还有受保护访问，就不能被 delete。

所以这次 PR 的核心不是“给裸指针加判空”，而是把旧的裸指针访问改成明确协议：

```text
先确认这个 Context 仍在 Runtime 管理集合里
  -> 再确认 magic 没坏、状态允许访问
  -> 需要使用对象时增加 in-use 计数
  -> 使用结束后减少 in-use 计数
  -> 如果 context 已标记删除且所有引用都退出，最后一个退出者负责真正 delete
```

一句话：

> `Context` 从“大家默认可信的裸指针”，变成了 Runtime 的生命周期、访问权限、资源归属和错误状态的共同边界。

## 2. Context 的两类引用

这次最容易混淆的是 `count_` 和 `threadRefCount_`。它们都能阻止非 primary context 被 delete，但语义不同。

| 计数 | 中文理解 | 谁增加 | 谁减少 | 主要作用 |
|---|---|---|---|---|
| `count_` | 正在使用中的 API/资源访问 | `ContextAcquire`、`CHECK_CONTEXT_VALID_WITH_RETURN`、`CheckContextIsValid(..., true)` | `ContextProtect` 析构 | 保护一段真实访问区间，destroy/reset 会等它降下来 |
| `threadRefCount_` | 当前线程还绑定着这个 context | `SetCurCtx/SetCurRef` 绑定 user context/ref 时 | `SetCurCtx/SetCurRef` 切走或清空时 | 防止线程 TLS 里还挂着旧指针时对象被 delete |

重要区别：

- `WaitUntilInUseCount()` 等的是 `count_`，不是 `threadRefCount_`。
- 线程只是把某个 context 设成当前上下文，不会让 destroy 等满 100ms。
- 真正拖住 destroy 的，是已经进入某个 API 或资源函数并拿到 in-use 引用的路径。

可以这样理解：

```text
threadRefCount_：
  “这个线程桌面上还放着这个 context 的名片，先别把对象 delete 掉。”

count_：
  “这段代码正在真正使用这个 context，destroy/reset 必须等我用完。”
```

## 3. Context 状态机

这次新增了 `ContextState`：

| 状态 | 含义 | USER 访问 | INTERNAL 访问 |
|---|---|---:|---:|
| `NOT_INITIALIZED` | 对象存在，但资源未初始化或已释放 | 否 | 否 |
| `INITIALIZING` | setup 正在进行 | 否 | 是 |
| `ACTIVE` | 正常可用 | 是 | 是 |
| `FINALIZING` | teardown 已开始，阻断新用户访问 | 否 | 是 |
| `FINALIZED` | teardown 已完成，但对象可能还没 delete | 否 | 否 |
| `DEINITIALIZING` | 资源释放或 delete 中 | 否 | 否 |

`USER` 是普通用户 API 路径。`INTERNAL` 是 reset/destroy/teardown 内部清理路径。

设计目的很清楚：

```text
准备销毁 context
  -> ACTIVE 切到 FINALIZING
  -> 新 USER API 进不来
  -> 已经进来的 USER API 继续跑完并释放 in-use 引用
  -> INTERNAL 清理路径继续访问必要资源
  -> 清理完成后释放资源并进入 FINALIZED/NOT_INITIALIZED
```

这个状态机是 PR 防 UAF 的核心。没有状态机，Runtime 只能靠“这个指针看起来还没空”判断是否可用；有状态机后，Runtime 能区分“对象还在内存里”和“对象还能给用户访问”。

## 4. 核心保护接口

### 4.1 `ContextManage::CheckContextIsValid()`

位置：

- `src/runtime/core/src/context/context_manage.cc`

这是本次防 UAF 的入口闸门。

它做四件事：

1. 判断 `ctx` 是否为空。
2. 读全局 context set，确认这个指针是不是 Runtime 仍然跟踪的 context。
3. 检查 `magic_` 和 `ContextState`，区分“真实可访问对象”和“已经销毁/正在销毁的旧指针”。
4. 如果调用方传 `inUseFlag=true`，就执行 `ContextInUse()`，给 `count_` 加一。

典型语义：

```text
CheckContextIsValid(ctx, false, USER)
  只校验，不保护使用区间。

CheckContextIsValid(ctx, true, USER)
  校验成功后 count_ + 1，调用方必须用 ContextProtect 接住。

CheckContextIsValid(ctx, true, INTERNAL)
  teardown/reset 内部路径使用，允许 INITIALIZING/FINALIZING 阶段访问。
```

性能影响也来自这里。以前很多地方只是：

```cpp
ctx->TaskGenCallback_()
```

现在变成：

```text
读全局 context set 锁
  -> 查 context 是否仍被跟踪
  -> 检查 magic/state
  -> 可能 atomic add count_
```

这带来安全收益，也会带来读锁和 atomic 成本。

特殊点：如果 context 已经从全局 set 移除，但当前线程仍然以内路径绑定着它，且 magic/state 仍允许 `INTERNAL` 访问，`CheckContextIsValid()` 允许通过。这是给 teardown 自己清理用的通道，不应该被普通 USER 路径使用。

### 4.2 `ContextAcquire`

位置：

- `src/runtime/core/inc/context/context_guard.hpp`
- `src/runtime/core/src/context/context_protect.cc`

`ContextAcquire` 可以理解成“拿一张临时通行证”。

典型用法：

```cpp
const ContextAcquire ctxGuard(rawCtx, ContextAccessMode::USER);
if (!ctxGuard) {
    return ctxGuard.error();
}
Context *ctx = ctxGuard.get();
```

构造时：

```text
CheckContextIsValid(rawCtx, true, mode)
  -> 成功则 ContextInUse()
  -> 保存 ctx_
  -> 用 ContextProtect 接住这份引用
```

析构时：

```text
ContextProtect::~ContextProtect()
  -> ContextOutUse()
  -> TryDeleteIfNeeded()
```

它适合资源对象内部使用，比如 `Stream`、`Event`、`Notify`、`Model` 持有一个 `context_` 裸指针，但真正访问前先 acquire，避免这个裸指针已经变成悬空指针。

### 4.3 `CHECK_CONTEXT_VALID_WITH_RETURN`

位置：

- `src/runtime/core/inc/context/context.hpp`

这个宏常见于 API 入口：

```cpp
Context * const curCtx = CurrentContext();
CHECK_CONTEXT_VALID_WITH_RETURN(curCtx, RT_ERROR_CONTEXT_NULL);
```

它不是简单检查宏，而是“API 入口保护当前 context 生命周期”的宏。

语义是：

```text
CheckContextIsValid(curCtx, true)
  -> 成功时已经 count_ + 1
ContextProtect curCtxCp(curCtx, EXISTING_IN_USE_REF)
  -> 函数退出时 count_ - 1
```

看到它就要意识到：当前函数作用域内，`curCtx` 不能被真正 delete。

### 4.4 `ContextProtect`

位置：

- `src/runtime/core/inc/context/context_protect.hpp`
- `src/runtime/core/src/context/context_protect.cc`

`ContextProtect` 是最底层的“离开作用域时释放引用”的对象。

它有两种模式：

| 模式 | 用法 |
|---|---|
| `NEW_IN_USE_REF` | 构造时自己执行 `ContextInUse()` |
| `EXISTING_IN_USE_REF` | 调用方已经通过 `CheckContextIsValid(..., true)` 拿过引用，只负责析构释放 |

这次代码大量用的是 `EXISTING_IN_USE_REF`，因为 acquire/check 成功时已经加过 `count_`，不能重复加。

### 4.5 `InnerThreadLocalContainer::SetCurCtx/SetCurRef`

位置：

- `src/runtime/core/inc/common/inner_thread_local.hpp`
- `src/runtime/core/src/common/inner_thread_local.cpp`

这两个接口管理“当前线程绑定的 context”：

- `SetCurCtx(ctx)`：显式设置当前 context，常见于 `rtCtxSetCurrent`、跨 context stream sync。
- `SetCurRef(ref)`：设置 primary context 的引用对象，常见于 `rtSetDevice`。

旧逻辑基本是 TLS 赋值；新逻辑还会维护 `threadRefCount_`。

新逻辑大致是：

```text
解析旧绑定 context
解析新绑定 context
判断旧绑定是否需要 thread ref
判断新绑定是否需要 thread ref
如果从 user ctxA 切到 user ctxB：
  ctxA->ContextThreadUnbind()
  ctxA->TryDeleteIfNeeded()
  ctxB->ContextThreadBind()
写入 curCtx_/curRef_/device_
```

注意：不是每次都 atomic 加减。只有绑定对象变化，或者 user/internal 语义变化时才会改 `threadRefCount_`。但每次调用都会多做 TLS 读取、ref 解析和分支判断，所以高频 context switch 仍然可能产生可测开销。

## 5. API 边界接口

### 5.1 `ApiImpl::CurrentContext()` / `Runtime::CurrentContext()`

位置：

- `src/runtime/core/src/api_impl/api_impl.cc`
- `src/runtime/core/src/runtime.cc`

这两个接口负责回答：

> 当前线程现在应该使用哪个 context？

查找顺序是：

```text
先看显式 curCtx_
  -> 再看 primary context ref，即 curRef_
  -> 都没有时，ApiImpl::CurrentContext() 可能触发隐式 set device
```

本次改动后，返回前会检查 context 是否仍然有效。这样可以避免线程 TLS 里还留着旧指针，但对象已经 teardown/delete 的 UAF。

这里的 `Context` 角色是“当前 API 默认资源域”。例如：

- 用户没有显式传 stream，Runtime 就从当前 context 取 default stream。
- 用户查询 context 级错误，就从当前 context 取 last error。
- 用户提交默认设备相关操作，就从当前 context 找 device。

### 5.2 `ApiImpl::SetDevice()`

位置：

- `src/runtime/core/src/api_impl/api_impl.cc`

`SetDevice(devId)` 的核心是拿到 device 对应的 primary context。

流程：

```text
Runtime::PrimaryContextRetain(devId)
  -> 初始化或复用 primary Context
  -> RefObject 引用计数加一
InnerThreadLocalContainer::SetCurRef(contextRef)
CHECK_CONTEXT_VALID_WITH_RETURN(curCtx)
InnerThreadLocalContainer::SetCurCtx(nullptr)
```

这里 context 的作用是“device 的默认运行环境”。

用户只说 set device，并没有创建显式 context，所以 Runtime 把当前线程绑定到 primary context ref。之后 `CurrentContext()` 会通过 `curRef_` 找到 primary context。

这次改动的重点是：primary context release/reset 后对象可能保留并重新初始化，不能让 TLS 持有的 ref 指向已经释放资源的非法状态而继续被用户路径访问。

### 5.3 `ApiImpl::ContextSetCurrent()`

位置：

- `src/runtime/core/src/api_impl/api_impl.cc`

`ContextSetCurrent(ctx)` 是显式切换当前线程上下文。

新逻辑：

```text
ctx == nullptr:
  清空 curCtx_ 和 curRef_

ctx != nullptr:
  CheckContextIsValid(ctx, false, USER)
  SetCurCtx(ctx)
  SetCurRef(nullptr)
```

这里没有拿 in-use 引用，因为“设为当前 context”不是进入某个具体 API 访问区间。它靠 `threadRefCount_` 保证 TLS 绑定期间对象不被 delete。

真正访问资源时，API 入口或资源对象仍要再拿 `count_` 引用。

### 5.4 `ApiImpl::ContextDestroy()`

位置：

- `src/runtime/core/src/api_impl/api_impl.cc`

显式 context destroy 是本次防 UAF 的主线之一。

流程：

```text
CheckContextIsValid(inCtx, true, USER)
  -> 当前 destroy 线程拿到 in-use 引用
ContextProtect cp(inCtx, EXISTING_IN_USE_REF)
禁止销毁 primary context
TearDownIsCanExecute()
  -> ACTIVE 切到 FINALIZING，阻断新的 USER 访问
WaitUntilInUseCount(1)
  -> 等其他已经进入的 API 退出，只保留当前 destroy 线程这一份引用
SetInternalThreadContext(inCtx)
  -> 以内路径身份执行 teardown
inCtx->TearDown()
SetTearDownExecuteResult()
ReleaseResourcesAfterTearDown()
SetContextDeleteStatus()
TryDeleteIfNeeded()
```

这里 context 的作用是“销毁边界的仲裁者”：先阻断新访问，再等老访问退场，最后释放资源。

`expectCount=1` 的原因是 destroy 自己手里就有一份 in-use 引用。

如果 `CheckContextIsValid()` 发现 context 已经不在 ACTIVE，但仍处于 `NOT_INITIALIZED/FINALIZED` 等可销毁尾态，会走 `AcquireInactiveContextForDestroy()`，允许把半初始化或已 teardown 对象收尾掉。

### 5.5 `Runtime::PrimaryContextRetain()`

位置：

- `src/runtime/core/src/runtime.cc`

primary context 是 `rtSetDevice` 背后的默认 context。

`PrimaryContextRetain()` 做的是：

```text
检查 devId/tsNum
对每个 TS 的 RefObject 加引用
如果第一次 retain：
  PreparePrimaryContext()
  InitializePrimaryContext()
  ContextManage::InsertContext()
  refObj.SetVal(ctx)
返回当前线程 TS 对应的 RefObject
```

这里 context 的作用是“设备级默认上下文对象”。它不是每次 set device 都创建新对象，而是由 `RefObject` 管引用计数。多次 set device 或多个线程绑定同一 device 时，可以共享 primary context。

### 5.6 `Runtime::PrimaryContextRelease()` / `ApiImpl::DeviceReset()` / `ResetDeviceForce()`

位置：

- `src/runtime/core/src/runtime.cc`
- `src/runtime/core/src/api_impl/api_impl.cc`

`DeviceReset()` 和 `ResetDeviceForce()` 最终都落到 `PrimaryContextRelease()`。

这条路径和 `ContextDestroy()` 类似，但有 primary context 的特殊语义：

- 普通 reset 会先 `TryDecRef()`，只有 primary ref 归零才真正 teardown。
- force reset 会持续减引用直到触发 reset。
- teardown 前用 `CheckContextIsValid(ctx, true, INTERNAL)` 拿 in-use 引用。
- 进入 `FINALIZING` 后设置 `PrimaryCtxCallBackFlag`，让内部回调能继续拿到 context。
- 调用 `PrimaryContextCallBack()`、`WaitUntilInUseCount(1)`、`TearDown()`、`Device::PrepareStop()`。
- 成功后 `ReleaseResourcesAfterTearDown()`，但 primary context 对象本身不一定 delete，后续可以重新 setup。

这里 context 的作用是“reset 期间的资源壳”。PR 的关键变化是 primary context reset 后可以保留对象壳，释放内部资源，再允许下一次 retain 重新 attach/setup，避免旧线程或回调路径直接 UAF。

## 6. Stream 相关接口

### 6.1 `ApiImpl::StreamSynchronize()`

位置：

- `src/runtime/core/src/api_impl/api_impl.cc`

`StreamSynchronize()` 是这次性能分析最重要的用户可见接口。

顶层流程：

```text
curCtx = CurrentContext()
CHECK_CONTEXT_VALID_WITH_RETURN(curCtx)
ValidateStreamSynchronizeHandle(stm, curCtx)
CheckStreamSynchronizeParam(curStm, curCtx)
如果 curStm->Context_() != curCtx:
  ContextSetCurrent(curStm->Context_())
curStm->CheckContextStatus()
curStm->Synchronize(false, timeout)
如果切过 ctx:
  ContextSetCurrent(curCtx)
MemPoolTrimImplicit(false)
```

在这个接口里，context 扮演五个角色：

1. **默认 stream 来源**：`stm == nullptr` 时，用 `curCtx->DefaultStream_()`。
2. **stream 合法性依据**：判断传入 stream 是否属于当前 context 或某个仍有效 context。
3. **生命周期保护**：入口宏保护 `curCtx`，避免同步期间当前 context 被 delete。
4. **跨 context 兼容**：如果用户拿另一个 context 的 stream 来同步，会临时切到 stream 所属 context。
5. **错误状态来源**：同步前和等待循环中通过 context 检查 device/context failure。

流同步本身等待的是：

> 这条 stream 上已经提交的任务是否执行并回收完成。

它不是等待 context。context 是同步过程的资源域、安全边界和错误状态来源。

### 6.2 `Stream::CheckContextStatus()`

位置：

- `src/runtime/core/src/stream/stream.cc`

这是同步等待循环里的关键函数。

逻辑：

```text
如果 stream->context_ == nullptr:
  只检查 device 状态
否则:
  AcquireContext()
  ctx->CheckStatus(this, isBlockDefaultStream)
```

`Context::CheckStatus()` 会检查：

- device running state
- driver/device status
- 特殊控制流是否可以跳过 context failure
- context failure error
- `STOP_ON_FAILURE`/`CONTINUE_ON_FAILURE` 语义

这次 PR 后，`CheckContextStatus()` 每次都会 acquire context。安全上是对的，因为 stream 里的 `context_` 是裸指针；性能上会放大，因为它在多个等待循环内反复调用。

### 6.3 `Stream::Synchronize()`

位置：

- `src/runtime/core/src/stream/stream.cc`

`Stream::Synchronize()` 是真正干同步工作的函数，主要分三条路：

| 路径 | 行为 | Context 作用 |
|---|---|---|
| STARS 平台 | `StarsWaitForTask()` 或 `SynchronizeImpl()` | 等待循环内反复 `CheckContextStatus()`；结束后 acquire context 弹出错误信息 |
| disable-thread | `WaitForTask()` | 轮询 task reclaim，循环内检查 context 状态 |
| 普通路径 | 创建临时 `Event`，`event->Record(this)` 后 `event->Synchronize(timeout)` | event record 提交任务时也要从 stream context 取 `TaskGenCallback_()` |

因此 `StreamSynchronize()` 的性能影响分两层：

- 快速完成时，主要是入口 context 校验和一次状态检查。
- 需要轮询等待时，每轮 `CheckContextStatus()` 都可能带来 `ContextInUse/OutUse` 原子开销。

### 6.4 等待循环：`SynchronizeExecutedTask()` / `WaitConcernedTaskRecycled()` / `WaitForTask()` / `StarsWaitForTask()`

这些函数都是“等任务进度”的循环：

- `SynchronizeExecutedTask()`：等 SQ 上的目标 task 执行完成。
- `WaitConcernedTaskRecycled()`：等相关 task 被回收。
- `WaitForTask()`：disable-thread 路径轮询回收进度。
- `StarsWaitForTask()`：STARS 平台轮询 task reclaim。

它们共同点是：循环里会调用 `CheckContextStatus(false)`。

这样做的目的：

- 等待期间如果 device/context/stream 发生 abort 或 failure，API 能及时返回错误。
- 不至于任务已经异常，但用户线程还一直等 task id。
- 遵守 context failure mode，比如 `STOP_ON_FAILURE`。

性能问题也在这里：

```text
while (...) {
    CheckContextStatus(false)
      -> AcquireContext()
         -> context set read lock
         -> magic/state check
         -> ContextInUse() atomic add
      -> ctx->CheckStatus()
      -> ContextOutUse() atomic CAS sub
      -> TryDeleteIfNeeded()
}
```

如果任务很快完成，这个成本不明显；如果同步等待需要多轮轮询，`ContextInUse/OutUse` 会被放大，尤其多线程同时 sync 同一个 context 时，会形成 `count_` cacheline 竞争。

### 6.5 Stream 提交任务路径

本次 PR 还把若干 task submit 从直接使用：

```cpp
stm->Context_()->TaskGenCallback_()
```

改成：

```text
从 stream 取 raw context
ContextAcquire(rawCtx)
dev->SubmitTask(task, ctx->TaskGenCallback_())
```

这个模式出现在 stream、event、notify、launch、task submit 等多处。

context 在这里的作用是“task 生成回调和上下文归属来源”。如果 context 正在 teardown，USER 路径不能再提交新 task；如果是 INTERNAL 清理路径，则可以按模式允许必要的清理任务。

## 7. Event / Notify / IPC Event

### 7.1 Event

位置：

- `src/runtime/core/src/event/event.cc`

`Event` 自己也保存 `context_`，但 event 的关键操作往往是通过 stream 提交 task。

相关接口包括：

- `Event::Record()`
- `Event::Wait()`
- `Event::QueryEventTask()`
- `Event::Synchronize()`
- `Event::ReAllocId()`
- event destroy/free id 相关路径

context 在 Event 里的作用：

1. 创建 event 时记录它归属哪个 context/device。
2. record/wait/reset task 提交时，通过 stream 的 context 获取 `TaskGenCallback_()`。
3. query/synchronize 时，通过 record stream 检查 context/device 状态。
4. teardown 时避免 event 持有的 context 或 stream 已经失效还继续解引用。

简单说：

> Event 是“流上的时间点/同步点”，Context 是“这个同步点属于哪个运行环境、能不能继续提交和等待”。

### 7.2 Notify

位置：

- `src/runtime/core/src/notify/notify.cc`

`Notify` 和 event 类似，也是 stream 上提交 notify record/wait/reset task。

典型接口：

- `Notify::Setup()`
- `Notify::ReAllocId()`
- `Notify::Record()`
- `Notify::Reset()`
- `Notify::RevisedWait()`
- `Notify::Wait()`
- `Notify::CheckIpcNotifyDevId()`
- `Notify::OpenIpcNotify()`

`Notify::Setup()` 和 IPC notify open 会从 `Runtime::CurrentContext()` 获取当前 context，然后拿 device/driver 分配 notify id。

`Record/Wait/Reset` 则用 `SubmitTaskWithStreamContext()`：

```text
streamIn->Context_()
  -> ContextAcquire(..., USER)
  -> ctx->TaskGenCallback_()
  -> dev->SubmitTask(...)
```

这里 context 的作用可以概括成两句：

- 创建/open 阶段：决定 notify 资源在哪个 device/TS 上分配。
- record/wait/reset 阶段：决定 task 能否在 stream 所属 context 下合法提交。

### 7.3 IpcEvent

位置：

- `src/runtime/core/src/event/ipc_event.cc`

IPC event 牵涉跨进程共享内存、P2P、handle import/export，所以更依赖 context 的 device 信息。

典型接口：

- `IpcEvent::Setup()`
- `IpcEvent::IpcGetEventHandle()`
- `IpcEvent::IpcOpenEventHandle()`
- `IpcEvent::IpcEventRecord()`
- `IpcEvent::IpcEventWait()`

这些接口现在会在访问 `context_` 前 `ContextAcquire(context_, USER)`。

context 在这里的作用：

1. 提供 `ctx->Device_()->Id_()`，检查驱动能力。
2. 确定 import/export、P2P enable、mem map 使用的是哪个 device。
3. 保证 IPC event 持有的 `context_` 没有在另一个线程 reset/destroy 中变成悬空指针。

IPC event 通常不是极致热路径，因此这部分更偏安全收益。

## 8. Model / ACLGraph

### 8.1 Model

位置：

- `src/runtime/feature/model/model.cc`
- `src/runtime/core/inc/model/model.hpp`

`Model` 是这次支线适配代码量最大的资源对象之一。它持有 `context_`、stream 列表、head stream、execute stream、AICPU 模型资源、destroy callback 等。

典型接口：

- `Model::Setup()`
- `Model::TearDown()`
- `Model::Execute()` / `ExecuteAsync()`
- `Model::SynchronizeExecute()`
- `Model::AddStream()` / `DelStream()`
- `Model::BindStream()` / `UnbindStream()`
- `Model::ModelAbort()`
- `Model::AicpuModelDestroy()`
- `Model::ReSetup()` / `ReBindStreams()` / `ReAllocStreamId()`
- `Model::ModelDestroyCallback()`

context 在 Model 中的作用更重：

- 它是 model 归属的资源域，决定 model 下面的 streams 属于哪个 device/context。
- 它提供模型执行和维护 task 的 `TaskGenCallback_()`。
- 它负责创建/销毁 model stream、default stream 关联、AICPU stream 绑定。
- 它在 teardown 时决定哪些清理可以继续做，哪些用户执行必须拒绝。
- 它承载 model failure 到 context failure 的传播。

本次改动的关键是：Model 的析构、teardown、abort、stream bind/unbind 路径不再默认相信 `context_` 仍有效，而是使用 `AcquireContext(USER/INTERNAL)`。

判断规则：

- 用户执行路径：用 `USER`。
- 销毁/清理路径：用 `INTERNAL`。
- 纯本地容器清理、且不访问 context/device 资源：可以不 acquire。

### 8.2 CaptureModel / ACLGraph

位置：

- `src/runtime/feature/aclgraph/capture_model.cc`
- `src/runtime/feature/aclgraph/model_aclgraph.cc`

`CaptureModel` 比普通 model 更复杂，因为它会额外管理 capture stream、原始 stream、execute notify、active task、profiling 上报信息。

典型接口：

- `CaptureModel::ExecuteCommon()`
- `CaptureModel::TearDown()`
- `CaptureModel::AddStreamToCaptureModel()`
- `CaptureModel::BuildSqCq()`
- `CaptureModel::ReleaseSqCq()`
- `CaptureModel::BindStreamToModel()`
- `CaptureModel::UnBindStreamFromModel()`
- `CaptureModel::ReportedStreamInfoForProfiling()`
- `CaptureModel::EraseStreamInfoForProfiling()`
- `CaptureModel::UpdateNotifyId()`
- `CaptureModel::RebuildStream()`

context 在 capture model 里的作用是“把一组被 capture 的 stream 重新组织成可执行模型时的资源根”。

它需要通过 context：

- 找 device。
- 建 SQ/CQ。
- 插入/移除 stream list。
- 更新 end-graph notify。
- 上报 profiling device id。

PR 的适配重点是：capture teardown 可能发生在 context `FINALIZING` 阶段，所以清理类操作要走 `INTERNAL`，用户执行/新增 stream 要走 `USER`。

## 9. Launch / Task / Engine

### 9.1 Launch 接口

涉及文件包括：

- `src/runtime/core/src/launch/aicpu_stars.cc`
- `src/runtime/core/src/launch/aix_stars.cc`
- `src/runtime/core/src/launch/aix_starsv2.cc`
- `src/runtime/core/src/launch/label.cc`
- `src/runtime/core/src/launch/label_stars.cc`
- `src/runtime/core/src/launch/cond_stars.cc`
- `src/runtime/core/src/launch/memory_common.cc`
- `src/runtime/core/src/launch/memory_stars.cc`
- `src/runtime/core/src/launch/memory_starsv2.cc`
- `src/runtime/core/src/launch/cmo_barrier_common.cc`
- `src/runtime/core/src/launch/cmo_barrier_stars.cc`

它们共同模式是：

```text
stream -> context -> device/callback -> SubmitTask
```

context 在这些接口里的作用是：

- 确定 task 属于哪个 stream/context/device。
- 提供 `TaskGenCallback_()`。
- 阻止已 teardown context 上继续提交用户 task。
- 在内部清理路径保留必要 task submit 能力。

这次改动的安全点是：不能直接 `stm->Context_()->TaskGenCallback_()`，因为 stream 可能还活着，但所属 context 正在 teardown。要先 acquire stream context，确认 USER 路径仍可提交 task。

### 9.2 Task / Engine 回调路径

涉及文件包括：

- `src/runtime/core/src/task/task_submit/v200/task_david.cc`
- `src/runtime/core/src/task/task_recycle/v200/task_recycle_send_sync.cc`
- `src/runtime/core/src/task/task_recycle/v200/task_recycle_cqrpt_base.cc`
- `src/runtime/core/src/task/task_info/model/model_execute_task.cc`
- `src/runtime/core/src/engine/stars/stars_engine.cc`
- `src/runtime/core/src/engine/hwts/direct_hwts_engine.cc`

task submit、task recycle、engine 回调里，context 的作用偏“后台状态恢复和错误处理”：

- task submit 前检查 stream context 状态，避免向已 teardown context 继续发任务。
- task recycle 或 complete callback 中，有时需要 `SetInternalThreadContext(stm->Context_())`，让错误处理、回调、清理逻辑以内路径访问 context。
- engine 等待或异常路径通过 `stm->CheckContextStatus(false)` 读取 context/device failure。

这里要注意：后台线程不是用户 API 线程，它可能没有正常的 `curCtx_`。因此 PR 增加 internal context access 的目的之一，就是让后台清理/回调有一条受控路径，不需要伪装成用户 API。

## 10. Device / RawDevice / XPU

### 10.1 Device reset 与 raw device stop

涉及文件包括：

- `src/runtime/core/src/device/raw_device.cc`
- `src/runtime/core/src/device/device_error_proc.cc`
- `src/runtime/core/src/runtime.cc`
- `src/runtime/core/src/api_impl/api_impl.cc`

Device 相关改动主要服务 reset/teardown：

- reset 前后需要等待 printf parse、通知 device state callback。
- primary stream、ctrl stream、SQ/CQ 资源释放时，context 可能已经不接受 USER 访问。
- `Device::PrepareStop()` 放在 primary context release 中、context 仍允许 INTERNAL task send 的窗口执行。

context 在这里是“device 资源释放顺序的协调者”。它不能太早释放 device 指针，否则 stream/model/event 清理还需要 device；也不能太晚开放 USER 访问，否则 reset 期间会有新任务进来。

### 10.2 XPU

涉及文件包括：

- `src/runtime/feature/xpu/runtime_xpu_adapt.cc`
- `src/runtime/feature/xpu/xpu_context.cc`
- `src/runtime/feature/xpu/stream_xpu.cc`

XPU 的语义和通用 context 一致：

```text
release 前先 TearDownIsCanExecute()
  -> WaitUntilInUseCount(1)
  -> TearDown()
  -> ReleaseResourcesAfterTearDown()
```

区别在于 XPU 有自己的 stream/context 实现细节，所以需要单独适配，确保 XPU stream 的 teardown/status 也不再裸用失效 context。

## 11. 这次需求中 Context 的作用总表

| 接口/模块 | Context 在其中的角色 | 本次 PR 主要变化 | 性能关注 |
|---|---|---|---|
| `CurrentContext()` | 当前线程默认资源域 | 返回前校验 TLS/ref 中的 context 是否仍有效 | 多一次 set 锁/状态检查 |
| `SetDevice()` | 绑定 primary context ref | retain primary context 后维护 thread binding | 高频 set device 会多 TLS/ref/atomic 成本 |
| `ContextSetCurrent()` | 显式切换线程当前 context | 设置前校验，绑定时维护 `threadRefCount_` | 跨 context 高频切换可测 |
| `ContextDestroy()` | 显式 context teardown 仲裁者 | 阻断 USER、等待 in-use、INTERNAL 清理、延迟 delete | destroy 可能等到 100ms timeout |
| `PrimaryContextRelease()` | primary context reset/release | ref 归零后释放资源但保留对象壳 | reset latency 和等待 in-use |
| `StreamSynchronize()` | stream 同步的资源域和错误状态来源 | 入口校验、stream 指针校验、跨 ctx 切换、循环状态检查 | 等待循环反复 acquire 是重点 |
| `Stream::CheckContextStatus()` | 等待/提交前检查 context/device failure | 裸 `context_` 改为 acquire 后检查 | 循环内 atomic add/sub 放大 |
| `Event::Record/Wait/Query` | event task 的上下文归属 | 提交/查询前保护 stream context | record/wait 高频时增加 acquire |
| `Notify::Record/Wait/Reset` | notify task 的上下文归属 | `SubmitTaskWithStreamContext()` 统一 acquire | notify 高频提交增加 acquire |
| `IpcEvent::*` | IPC handle/P2P/device 能力来源 | 访问 `context_` 前 acquire | IPC 非热路径，安全收益大 |
| `Model::*` | model 资源根和 stream 集合归属 | execute 用 USER，teardown 用 INTERNAL | model teardown/execute 路径变重 |
| `CaptureModel::*` | capture stream 重组和 profiling device 来源 | 多处补 acquire，清理路径用 INTERNAL | graph capture/rebuild 路径关注 |
| Launch/Task | `TaskGenCallback_()` 来源 | task submit 前先 acquire stream context | task submit 热路径需压测 |
| Engine/Recycle | 后台清理和错误传播上下文 | 回调/清理使用 internal context | 后台线程状态一致性 |
| XPU | XPU stream/context teardown 状态源 | 对齐通用 context 防 UAF 协议 | XPU release/reset latency |

## 12. 开发时怎么判断该用哪种 Context 保护

### 12.1 这是用户 API 入口吗？

如果从当前线程取 context 并直接使用，通常用：

```cpp
Context * const curCtx = CurrentContext();
CHECK_CONTEXT_VALID_WITH_RETURN(curCtx, RT_ERROR_CONTEXT_NULL);
```

适用场景：

- API 默认依赖当前 context。
- 需要从当前 context 取 default stream/device/error。
- 函数执行期间要保证当前 context 不被 delete。

### 12.2 这是资源对象里保存的 `context_` 裸指针吗？

如果是 `Stream`、`Event`、`Notify`、`Model` 内部访问自己的 `context_`，通常用：

```cpp
const ContextAcquire ctxGuard(context_, ContextAccessMode::USER);
if (!ctxGuard) {
    return ctxGuard.error();
}
```

适用场景：

- 资源对象活着，但它所属的 context 可能正在 teardown。
- 需要从 context 取 device/callback/failure 状态。
- 需要确认用户路径仍然允许访问。

### 12.3 这是 teardown/reset/destroy 内部清理吗？

如果已经进入 context release/destroy，并且需要继续清理资源，用：

```cpp
ContextAccessMode::INTERNAL
```

适用场景：

- `ContextDestroy()`
- `PrimaryContextRelease()`
- model/event/stream teardown
- 后台回调清理

不要让普通用户路径使用 `INTERNAL`。否则会绕过 `FINALIZING` 对 USER 的阻断。

### 12.4 只是把 context 设成当前线程上下文吗？

`ContextSetCurrent()` / `SetCurCtx()` 维护的是线程绑定引用，不等于进入受保护访问区。

这类代码保护的是：

```text
TLS 里还挂着这个 context 指针时，不要 delete 对象
```

它不保护：

```text
接下来一大段代码访问 context 内部资源的生命周期
```

后续真正读写 context 资源时仍要 acquire 或入口保护。

### 12.5 这个函数会循环调用吗？

如果会，比如 `StreamSynchronize()` 的等待循环，要特别小心把 `ContextAcquire` 放在循环里。

原因：

```text
每轮 acquire/release
  -> count_ atomic add
  -> count_ atomic CAS sub
  -> TryDeleteIfNeeded()
```

单次看很小，循环和多线程会放大。

优化方向是：外层已经持有保护时，让内层复用这个事实，避免重复 `ContextInUse/OutUse`。可以通过传参，也可以通过当前线程的临时“已保护 context 标记”来做；具体方案要看改动范围和风险。

### 12.6 这个 task submit 需要 `TaskGenCallback_()` 吗？

如果 callback 来自 context，不能裸取。

推荐模式：

```text
stream/model/context raw pointer
  -> ContextAcquire
  -> ctx->TaskGenCallback_()
  -> SubmitTask
```

这能避免 stream/model 仍活着，但它所属 context 已经 teardown 时继续提交任务。

## 13. 看代码时的三条主线

把这三条线分清，Runtime 里绝大多数 context 相关改动都能顺着看明白。

### 13.1 当前线程绑定线

```text
SetDevice
  -> PrimaryContextRetain
  -> SetCurRef
  -> CurrentContext

ContextSetCurrent
  -> SetCurCtx
  -> SetCurRef(nullptr)
```

这条线回答：

> 当前线程默认使用哪个 context？

### 13.2 访问保护线

```text
CheckContextIsValid(..., true)
  -> ContextInUse
  -> ContextProtect
  -> ContextOutUse
  -> TryDeleteIfNeeded

ContextAcquire
  -> 上面这组逻辑的 RAII 封装
```

这条线回答：

> 这段代码正在使用 context，如何保证它不会中途被 delete？

### 13.3 销毁清理线

```text
TearDownIsCanExecute
  -> ACTIVE -> FINALIZING
  -> WaitUntilInUseCount
  -> INTERNAL 清理
  -> ReleaseResourcesAfterTearDown
  -> SetContextDeleteStatus
  -> TryDeleteIfNeeded
```

这条线回答：

> 如何阻断新的用户访问，等待已有访问退出，并安全释放资源？

## 14. 最后一句话

这次 PR 之后，理解 Runtime 的关键不再是“这个对象里有没有 `Context *`”，而是看清它处在哪个阶段：

- 是当前线程绑定阶段？
- 是用户 API 访问阶段？
- 是资源对象持有裸指针阶段？
- 是 task submit 阶段？
- 是同步等待阶段？
- 是 teardown/reset 内部清理阶段？

不同阶段对 context 的保护方式不同。把阶段分清，就能判断应该用 `CHECK_CONTEXT_VALID_WITH_RETURN`、`ContextAcquire(USER)`、`ContextAcquire(INTERNAL)`、`SetCurCtx/SetCurRef`，还是需要避免循环内反复 acquire。

