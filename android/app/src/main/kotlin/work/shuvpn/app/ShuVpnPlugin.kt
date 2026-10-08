package work.shuvpn.app

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * [ShuVpnService] 的 Dart 侧入口。
 *
 * 通道是 `shuvpn/vpn`，**双向**使用：
 *
 * | 方向 | 方法 | 说明 |
 * | :--- | :--- | :--- |
 * | Dart → 原生 | `isPrepared` | 问一次 VPN 授权状态 |
 * | Dart → 原生 | `requestPermission` | 弹 VPN 授权对话框 |
 * | Dart → 原生 | `notificationGranted` | 问一次通知授权状态 |
 * | Dart → 原生 | `requestNotificationPermission` | 弹通知授权对话框（Android 13+） |
 * | Dart → 原生 | `attachForeground` | 起前台服务、不建 TUN（纯代理模式） |
 * | Dart → 原生 | `start` | 起服务、建 TUN，返回原始 fd |
 * | Dart → 原生 | `stop` | 停服务（关接口、撤通知） |
 * | Dart → 原生 | `updateNotification` | 换掉通知正文（上下行与延迟） |
 * | 原生 → Dart | `disconnectRequested` | 用户点了通知栏上的「断开」 |
 * | 原生 → Dart | `vpnRevoked` | 系统撤了这条 VPN（接口已不在） |
 *
 * 为什么两项授权都要 `ActivityAware`：它们都是**系统对话框**，必须由一个
 * 前台 Activity 发起 —— `VpnService.prepare()` 返回的 Intent 要用
 * `startActivityForResult` 启动，`POST_NOTIFICATIONS` 要走 `requestPermissions`，
 * 后台发起的话系统直接拒绝（后台启动 Activity 受限）。依赖包里那份也是
 * 同一个做法。
 */
class ShuVpnPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware {

    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var applicationContext: Context? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingNotification: MethodChannel.Result? = null

    /**
     * `waitForService` 是阻塞轮询，而 `vpnStart` 是在平台线程上被调用的 ——
     * 在这里面阻塞会等来 ANR（服务的 `onStartCommand` 也要跑在同一个线程上，
     * 永远等不到）。所以建接口这一步整个丢到单线程池里。
     */
    private val worker = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        instance = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
        if (instance === this) instance = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener { requestCode, resultCode, _ ->
            if (requestCode != PERMISSION_REQUEST_CODE) {
                false
            } else {
                val pending = pendingPermission
                pendingPermission = null
                pending?.success(resultCode == Activity.RESULT_OK)
                true
            }
        }
        binding.addRequestPermissionsResultListener { requestCode, _, grantResults ->
            if (requestCode != NOTIFICATION_REQUEST_CODE) {
                false
            } else {
                val pending = pendingNotification
                pendingNotification = null
                val permission =
                    grantResults.isNotEmpty() &&
                        grantResults[0] == PackageManager.PERMISSION_GRANTED
                // 运行期权限到手不等于通知会出现：用户还可以把整个应用的
                // 通知关在系统设置里，而那一层只有 `areNotificationsEnabled()`
                // 看得见（开了它之后 app 里再也弹不出对话框，只能去设置里开）。
                val enabled = permission && notificationsEnabled()
                // 允许之后补投一次：在权限到手之前 post 的那条通知进不了
                // 通知栏，而系统**不会**补发它（拒绝期间的通知不排队）。
                if (enabled) ShuVpnService.activeService?.repostNotification()
                pending?.success(enabled)
                true
            }
        }
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isPrepared" -> result.success(isPrepared())
            "requestPermission" -> requestPermission(result)
            "start" -> start(call, result)
            "attachForeground" -> {
                // 纯代理模式：只要那条常驻通知（与服务带来的进程保护），不建
                // TUN。服务已经在跑时再调一次也无妨（`startForeground` 是
                // 幂等的）。
                val context = context()
                if (context == null) {
                    result.error("no_context", "插件没有拿到可用上下文。", null)
                } else {
                    ShuVpnService.attach(context)
                    result.success(null)
                }
            }
            "stop" -> {
                context()?.let { ShuVpnService.detach(it) }
                result.success(null)
            }
            "updateNotification" -> {
                val text = call.argument<String>("text")
                // 服务不在（隧道已经拆了）时静默丢弃：那一两帧是在路上的，
                // 不是错误。
                if (!text.isNullOrEmpty()) {
                    ShuVpnService.activeService?.updateNotification(text)
                }
                result.success(null)
            }
            "notificationGranted" -> result.success(notificationsEnabled())
            "requestNotificationPermission" -> requestNotificationPermission(result)
            else -> result.notImplemented()
        }
    }

    /** 有授权时 `prepare()` 返回 null；没授权时返回一个要交给系统 UI 的 Intent。 */
    private fun isPrepared(): Boolean {
        val context = activity ?: applicationContext ?: return false
        return try {
            VpnService.prepare(context) == null
        } catch (_: Exception) {
            false
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val current = activity
        if (current == null) {
            result.error(
                "no_activity",
                "VPN 授权需要一个前台页面才能弹出系统对话框。",
                null,
            )
            return
        }
        val intent = VpnService.prepare(current)
        if (intent == null) {
            result.success(true)
            return
        }
        // 上一次请求还挂着就把它回掉，否则那个 Future 永远不会完成。
        pendingPermission?.error("cancelled", "A newer permission request started.", null)
        pendingPermission = result
        current.startActivityForResult(intent, PERMISSION_REQUEST_CODE)
    }

    /**
     * 当前能不能发通知。
     *
     * 问的是 `areNotificationsEnabled()` 而不是直接查 `POST_NOTIFICATIONS`：
     * 前者把「Android 13+ 的运行期权限」与「更低版本里用户在系统设置里关掉
     * 了通知」合成同一个答案 —— 而那个答案正是「隧道那条常驻通知到底会不会
     * 出现」。前者 API 24+，本应用的 minSdk 就是 24，不需要再判版本。
     */
    private fun notificationsEnabled(): Boolean {
        val context = context() ?: return false
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        return manager?.areNotificationsEnabled() ?: false
    }

    /**
     * 弹通知授权对话框。
     *
     * 只在「系统真有这个对话框、而且还没允许」时才弹：已经允许、或 Android 13
     * 以下没有运行期权限，直接回当前状态 —— 调用方重复调用是安全的。
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || notificationsEnabled()) {
            result.success(notificationsEnabled())
            return
        }
        val current = activity
        if (current == null) {
            result.error(
                "no_activity",
                "通知授权需要一个前台页面才能弹出系统对话框。",
                null,
            )
            return
        }
        pendingNotification?.error("cancelled", "A newer permission request started.", null)
        pendingNotification = result
        current.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST_CODE,
        )
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val context = context()
        if (context == null) {
            result.error("no_context", "插件没有拿到可用上下文。", null)
            return
        }
        val address = call.argument<String>("address")
        if (address.isNullOrEmpty()) {
            result.error("invalid_options", "VPN 接口地址为空。", null)
            return
        }
        val prefixLength = call.argument<Int>("prefixLength") ?: 32
        val mtu = call.argument<Int>("mtu") ?: 0
        val routes = call.argument<List<String>>("routes") ?: emptyList()
        val dnsServers = call.argument<List<String>>("dnsServers") ?: emptyList()
        val notificationTitle = call.argument<String>("notificationTitle") ?: "ShuVPN"
        val disconnectLabel = call.argument<String>("disconnectLabel") ?: "断开"

        worker.execute {
            ShuVpnService.attach(context)
            if (!waitForService()) {
                result.error("service_failed", "VPN 服务没有起来。", null)
                return@execute
            }
            val fd = try {
                ShuVpnService.activeService?.establish(
                    address = address,
                    prefixLength = prefixLength,
                    mtu = mtu,
                    routes = routes,
                    tunnelDnsServers = dnsServers,
                    notificationTitle = notificationTitle,
                    disconnectLabel = disconnectLabel,
                )
            } catch (error: Exception) {
                result.error("establish_failed", error.toString(), null)
                return@execute
            }
            if (fd == null || fd < 0) {
                result.error("establish_failed", "VpnService.Builder.establish() 没有返回描述符。", null)
            } else {
                result.success(fd)
            }
        }
    }

    private fun waitForService(
        timeoutMillis: Long = 5000,
        pollMillis: Long = 25,
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (ShuVpnService.activeService != null) return true
            Thread.sleep(pollMillis)
        }
        return ShuVpnService.activeService != null
    }

    private fun context(): Context? = activity?.applicationContext ?: applicationContext

    companion object {
        private const val CHANNEL = "shuvpn/vpn"
        private const val PERMISSION_REQUEST_CODE = 0x5348
        private const val NOTIFICATION_REQUEST_CODE = 0x5349

        @Volatile
        private var instance: ShuVpnPlugin? = null

        /** 由服务在用户点了通知栏的「断开」时调用。 */
        fun requestDisconnect() {
            instance?.channel?.invokeMethod("disconnectRequested", null)
        }

        /**
         * 由服务在系统撤掉这条 VPN 时调用（见 `ShuVpnService.onRevoke`）。
         *
         * 它可能在非主线程上被调到 —— 通道会自己把消息送到平台线程。
         */
        fun requestVpnRevoked() {
            instance?.channel?.invokeMethod("vpnRevoked", null)
        }
    }
}
