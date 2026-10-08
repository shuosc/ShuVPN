package work.shuvpn.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.system.OsConstants
import androidx.annotation.RequiresApi
import java.net.Inet6Address
import java.net.InetAddress

/**
 * ShuVPN 自己的 [VpnService]。
 *
 * ## 为什么要自己写一个，而不用依赖包里那个
 *
 * `flutter_sangfor` 0.0.5 的 `VpnTunnelService.establish()` 有一段
 * 「把 DNS 服务器排除在路由之外」的逻辑：
 *
 * ```kotlin
 * val effectiveDns = dnsServers.ifEmpty { underlyingDnsServers() }
 * for (route in routes) {
 *     if (effectiveDns.any { routeCovers(prefix, length, it) }) continue
 *     builder.addRoute(prefix, length)
 * }
 * ```
 *
 * 而 `routeCovers("0.0.0.0", 0, dns)` 里的掩码是 `0`，于是
 * `(0 and 0) == (dns and 0)` **恒为真** —— `0.0.0.0/0` 这条路由会被判定成
 * 「覆盖了 DNS 服务器」而被 `continue` 跳过。结果是 `Builder` 只 `addAddress`
 * 与 `addDnsServer`，**一条 `addRoute` 都没加**：TUN 接口建起来了、通知栏
 * 也出来了、`incoming` 却永远是空的 —— 表现就是「VPN 开着，但一个包都没
 * 被劫持」。而 `effectiveDns` 由 `underlyingDnsServers()` 兜底、几乎不可能
 * 为空，所以这个分支 100% 命中。
 *
 * 同一份代码还有第二个问题：它的注释写着「调用方会通过路由排除隧道节点」，
 * 但那段排除在代码里**并不存在**。即使路由修好，隧道自身用来连网关的
 * socket 也会被 `0.0.0.0/0` 吸进 TUN，绕回自己 → 隧道当场死掉。
 *
 * 两处都在包的原生代码里，app 侧改不动。所以这一层由自己实现，只复用包里
 * 公开导出的 `FdPacketDevice`（把 fd 变成包流）与 `SangforTunnelRouter`
 * （在 TUN 与隧道之间搬包）—— 那两块没有毛病。
 *
 * ## 这一份的取值
 *
 * | 项 | 取值 | 理由 |
 * | :--- | :--- | :--- |
 * | 路由 | 网关下发的全部网段 | 见 `vpn_routes.dart`：L3 是资源转发表 |
 * | TCP | 由 Dart 侧的终结器接住 | L3 对 TCP 有一道硬门，进去只会被静默丢弃 |
 * | IPv6 | `allowFamily(AF_INET6)` | **不接管，但也不封死** —— 见 [applyAddressFamilies] |
 * | 自身 | `addDisallowedApplication` | 隧道传输必须留在底层网络，否则自环 |
 * | DNS | 见 [establish] | 用户填的走隧道；自动回落的那组走底层 |
 */
class ShuVpnService : VpnService() {

    companion object {
        @Volatile
        var activeService: ShuVpnService? = null
            private set

        private const val CHANNEL_ID = "shuvpn_vpn"
        private const val NOTIFICATION_ID = 0x5348
        private const val ACTION_DISCONNECT = "work.shuvpn.app.action.VPN_DISCONNECT"

        /**
         * 起前台服务（幂等），**不**建 TUN。
         *
         * 两条数据面共用这一个服务：系统 VPN（建 TUN）与纯本机代理（只靠它
         * 把进程留在前台）。服务类是 [VpnService] 的子类，因为只有它能调
         * `Builder.establish()`；纯代理模式下它只是不调而已 —— 平级的第二个
         * 普通 `Service` 只会多出一条通知、多一套生命周期。
         */
        fun attach(context: Context) {
            val intent = Intent(context, ShuVpnService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * 停掉服务（连同通知）。
         *
         * 调用方要先确认**没有数据面还需要它**（见 `ConnectionController`
         * 的 `_detachForegroundIfIdle`）：纯代理模式下这一下会把进程的保护
         * 一并撤掉。
         */
        fun detach(context: Context) {
            context.stopService(Intent(context, ShuVpnService::class.java))
        }
    }

    private var notificationTitle = "ShuVPN"
    private var disconnectLabel = "断开"

    /**
     * 通知正文，一行读数（上下行与延迟），由 Dart 侧每秒一次的采样算好送
     * 过来（见 `ShuVpnNotification`）。
     *
     * 它同 [foregrounded]、[screenOn] 一样只在主线程上读写：通道回调、
     * `onStartCommand` 与广播接收器都在主线程。
     */
    private var contentText = "已连接"

    /**
     * 服务有没有进过前台。Dart 侧的第一帧可能比 `onStartCommand` 先到：
     * 插件在 worker 线程上轮询到 `activeService` 就返回 fd，那之后 Dart 立即
     * 推读数，而这一侧的 `startForeground` 排在后面。还没进前台时
     * [notifyContent] 什么都不做，那一次的文本会由 `onStartCommand` 里的
     * `startForeground` 带出去。
     */
    private var foregrounded = false

    /** 屏幕是不是亮着。息屏时不刷新通知，见 [updateNotification]。 */
    private var screenOn = true

    /**
     * 通知上那个时钟的取值，取服务创建的时刻（≈ 这条隧道建起来的时刻）。
     * **必须固定**：每秒重建通知时让它跟着 `build()` 走，那个位置会永远显示
     * 刷新时间，而不是这条隧道什么时候建起来的。
     */
    private val startedAt = System.currentTimeMillis()

    override fun onCreate() {
        super.onCreate()
        activeService = this
        registerScreenReceiver()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            ShuVpnPlugin.requestDisconnect()
        }
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        foregrounded = true
        // **不**用 `START_STICKY`：服务被系统回收意味着 VPN 已经断了
        // （fd 跟着 service 的授权走），自动重启只会留下一个「显示已连接、
        // 实际什么也不通」的前台通知。让通知消失，用户看得见断没断。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        activeService = null
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: IllegalArgumentException) {
            // 注册没成功过。拆服务不该因此失败。
        }
        super.onDestroy()
    }

    /**
     * 系统把这条 VPN 撤了（用户在系统设置里关掉、或另一个 VPN 应用抢走了它）。
     *
     * 接口此刻已经不在，fd 也跟着无效，但**服务本身不一定要停**：纯代理模式
     * 与「VPN + 代理」组合下，本机代理还在用同一条隧道。要不要停由 Dart 侧
     * 判定（它知道还有几个数据面在跑），所以这里**不调 `super.onRevoke()`**
     * —— 那个默认实现是 `stopSelf()`，会把代理的保护一并撤掉。
     *
     * 这个方法不保证跑在主线程（见 `VpnService` 的文档），所以这里只做一件事：
     * 把事实告诉 Dart 侧。
     */
    override fun onRevoke() {
        ShuVpnPlugin.requestVpnRevoked()
    }

    /**
     * 用最新的读数刷新通知正文。
     *
     * 由 `shuvpn/vpn` 通道每秒调一次（Dart 侧的采样循环）。
     *
     * 屏幕黑着时**只记住不发**：息屏时用户看不见通知，而每秒一次
     * `NotificationManager` 调用在 Doze 边缘是纯粹的浪费。亮屏那一刻由
     * [screenReceiver] 补发最新的一条，所以复屏后看到的是当前值，而不是
     * 息屏前的旧值。
     *
     * 门闸放在这一侧而不是 Dart 侧：Flutter 的 `paused` 分不清「息屏」与
     * 「切到别的应用但屏幕亮着」，而后者的情况下通知栏是**看得见**的。
     */
    fun updateNotification(text: String) {
        if (text.isEmpty()) return
        if (text == contentText) return
        contentText = text
        if (!screenOn) return
        notifyContent()
    }

    /** 重建并提交通知。还没进前台时什么都不做，见 [foregrounded]。 */
    private fun notifyContent() {
        if (!foregrounded) return
        try {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification())
        } catch (_: Exception) {
            // 通知权限被拒、或服务正在被拆掉。通知是装饰性的，不该把每秒
            // 一次的采样循环打断。
        }
    }

    /**
     * 幂等地重投一次通知，绕过 [updateNotification] 那道「内容没变就跳过」
     * 的判断。
     *
     * 通知授权是**事后**才可能到手的：在那之前 post 的那一条进不了通知栏，
     * 而系统不会补发（拒绝期间的通知不排队）。授权刚到手时（见
     * `ShuVpnPlugin` 的 `addRequestPermissionsResultListener`）读数字符串
     * 大概率与上一次相同 —— 隧道空闲时它一直不变 —— 所以那一次补投不能走
     * 去重那条路。
     */
    fun repostNotification() = notifyContent()

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val interactive = intent?.action == Intent.ACTION_SCREEN_ON
            if (interactive == screenOn) return
            screenOn = interactive
            // 息屏期间攒下的最新读数在这里补发一次。
            if (interactive) notifyContent()
        }
    }

    private fun registerScreenReceiver() {
        // 初值取系统状态：服务是在屏幕亮着的时候起来的，但这条广播不补发
        // 一次「当前亮着」。
        screenOn = (getSystemService(POWER_SERVICE) as? PowerManager)?.isInteractive ?: true
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }
    }

    /**
     * 建立 TUN 接口并把 fd 交给 Dart 侧，返回原始 fd；建立失败返回 null。
     *
     * [tunnelDnsServers] 是**期望走隧道**的 DNS：用户在设置里手填的，
     * 或者网关下发且落在资源网段内的那些（由 Dart 侧筛过）。
     *
     * 底层网络自己那一组**总是**会被追加在后面当兜底，并且（API 33+）
     * 被排除在隧道之外 —— 只在隧道 DNS 不可达时才会用到它们，这样
     * 「网关 DNS 不通」不会连带把公网域名解析也拖死。
     *
     * [routes] 是网关资源表展开后的**全部**网段。TCP 里 L3 背不动的那些
     * 由 Dart 侧的本机终结器接住（见 `connection_controller.dart` 的
     * `startVpn`），所以这一层不需要再做任何协议上的取舍，也不设系统代理。
     */
    fun establish(
        address: String,
        prefixLength: Int,
        mtu: Int,
        routes: List<String>,
        tunnelDnsServers: List<String>,
        notificationTitle: String,
        disconnectLabel: String,
    ): Int? {
        if (notificationTitle.isNotEmpty()) this.notificationTitle = notificationTitle
        if (disconnectLabel.isNotEmpty()) this.disconnectLabel = disconnectLabel

        val builder = Builder()
            .setSession("ShuVPN")
            .addAddress(address, prefixLength)

        if (mtu > 0) builder.setMtu(mtu)

        for (route in routes) {
            val separator = route.lastIndexOf('/')
            if (separator <= 0) continue
            val prefix = route.substring(0, separator)
            val length = route.substring(separator + 1).toIntOrNull() ?: continue
            builder.addRoute(prefix, length)
        }

        val throughTunnel = tunnelDnsServers.filter { it.isNotBlank() }.distinct()
        val underlying = underlyingDnsServers().filterNot { throughTunnel.contains(it) }
        // 没有任何 DNS 服务器时 VPN 网络解析不了名字（应用会拿到 0.0.0.0），
        // 所以隧道里那一组为空时要靠底层那一组顶上。
        for (dns in throughTunnel + underlying) {
            builder.addDnsServer(dns)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            excludeUnderlyingDnsFromTunnel(builder, underlying)
        }

        applyAddressFamilies(builder, address, routes + throughTunnel)

        // 关键的一步：把本应用排除在 VPN 之外。
        //
        // 隧道自己的传输是 dart:io 的 socket，目标是网关 / 节点地址。如果
        // 不排除，交给 TUN 的那些网段会把这批包也吸进来，交给隧道去转发 ——
        // 而隧道正是要靠这批包才能工作，于是自环。Android 的排除是**按 uid
        // 生效的**（`ip rule` 里的 uidrange），所以只影响本应用，
        // 别的应用照常被接管。
        try {
            builder.addDisallowedApplication(packageName)
        } catch (_: Exception) {
            // 包名就是自己，理论上不可能失败；真失败了也不要因此建不起隧道。
        }

        val descriptor = builder.establish() ?: return null
        return descriptor.detachFd()
    }

    /**
     * 把**没有接管**的地址族显式放行。
     *
     * ## 要解决的问题（这就是「VPN 开着但一个包都不进 TUN」的真因）
     *
     * `VpnService.Builder` 的默认行为是**封掉**没有配置过的地址族：
     *
     * > By default, if no address, route or DNS server of a specific family
     * > (IPv4 or IPv6) is added to this VPN, then all outgoing traffic of that
     * > family is blocked. … This method allows an address family to be unblocked
     * > even without adding an address, route or DNS server of that family.
     * > Traffic of that family will then typically fall-through to the underlying
     * > network if it's supported.
     * > —— `VpnService.Builder.allowFamily` 的官方文档
     *
     * 本应用只处理 IPv4：aTrust 的 L3 数据面就是 IPv4（`buildPacketMeta` 只解
     * 版本 4，`matchL3Route` 只比 IPv4 地址），所以一条 IPv6 地址 / 路由 / DNS
     * 都没有。默认行为于是把**整族 IPv6 流量封死**。
     *
     * 而现在的手机几乎都有 IPv6（运营商与校园网都是双栈），Android 解析出一个
     * 域名的 AAAA 记录后会**优先走 IPv6**。结果就是：接口建起来了、通知栏也在、
     * `incoming` 却几乎永远是空的 —— 看起来像「一个包都没劫持到」，实际是**全被
     * 系统在进 TUN 之前就丢了**。
     *
     * ## 为什么是「放行」而不是「加 `::/0` 一起接管」
     *
     * 加 `::/0` 确实能让 IPv6 包进 TUN，但隧道那一边解不了它们：
     * `ATrustTunnel.sendPacket` 只认 IPv4 头，IPv6 包会被它当垃圾丢掉 ——
     * 那等于把 IPv6 流量从「走底层网络」换成「进黑洞」，只会更糟。
     *
     * 所以正确的做法和 strongSwan / OpenVPN for Android 一致：**没接管的那一族
     * 显式放行，让它继续走底层网络**。这与 `vpn_routes.dart` 里「只接管网关资源
     * 网段」是同一条原则 —— 这是分流，不是全机代理。
     */
    private fun applyAddressFamilies(
        builder: Builder,
        address: String,
        configured: List<String>,
    ) {
        val entries = listOf(address) + configured
        val wantsIpv4 = entries.any { !it.contains(':') }
        val wantsIpv6 = entries.any { it.contains(':') }
        // API 21+；本应用的 minSdk 是 24，不需要再判版本。
        if (!wantsIpv4) builder.allowFamily(OsConstants.AF_INET)
        if (!wantsIpv6) builder.allowFamily(OsConstants.AF_INET6)
    }

    /**
     * 把底层网络那一组 DNS 排除到隧道之外（仅 API 33+ 支持）。
     *
     * 它们本来就取自底层网络（`ConnectivityManager`），排除之后必然可达；
     * 留在隧道里则要赌网关会转发 UDP 53 到这些公网地址。
     *
     * 低版本没有 `excludeRoute`，那组服务器会被留在隧道里 —— 与主流 VPN
     * 客户端的行为一致。这不是可以在 app 侧绕开的事，所以只记在注释里。
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun excludeUnderlyingDnsFromTunnel(builder: Builder, underlying: List<String>) {
        for (raw in underlying) {
            val address = parseAddress(raw) ?: continue
            val prefixLength = if (address is Inet6Address) 128 else 32
            builder.excludeRoute(IpPrefix(address, prefixLength))
        }
    }

    /** DNS 服务器地址来自系统，是 IP 字面量，`getByName` 不会发起解析。 */
    private fun parseAddress(raw: String): InetAddress? =
        try {
            InetAddress.getByName(raw)
        } catch (_: Exception) {
            null
        }

    /** 当前底层（非 VPN）网络的 DNS 服务器。 */
    private fun underlyingDnsServers(): List<String> {
        val manager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = manager.activeNetwork ?: return emptyList()
        val properties = manager.getLinkProperties(network) ?: return emptyList()
        return properties.dnsServers.mapNotNull { it.hostAddress }
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "VPN",
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val disconnectIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ShuVpnService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(notificationTitle)
            .setContentText(contentText)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setWhen(startedAt)
            .addAction(
                Notification.Action.Builder(null, disconnectLabel, disconnectIntent).build(),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // 安卓 12 起前台服务通知会被系统最多压后 10 秒才显示，而这一条
            // 是「VPN 正在跑」的唯一凭据。
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }
}
