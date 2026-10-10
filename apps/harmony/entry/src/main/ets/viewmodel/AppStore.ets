/**
 * Ordo · 视图模型(AppStore)
 * 契约来源:docs/04-UI设计规范.md §3(布局骨架)、§4(组件);docs/03-数据模型与同步协议.md §4(派生清单)
 *
 * 职责:
 *  - 组装本地存储(RDB,失败降级内存)、业务引擎(OrdoEngine)、同步引擎(SyncEngine)、实时通道(RealtimeClient)
 *  - 持有导航状态与浮层状态,向视图暴露"查询 + 动作"两类 API
 *  - 任何状态变化都 bump() 一次 changeSeq,配合 @Observed + @ObjectLink 驱动 ArkUI 重新渲染
 */

import { common } from '@kit.AbilityKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import {
  Area,
  CalendarEvent,
  ListKind,
  MAX_PUSH_OPS,
  Project,
  RepeatFreq,
  RepeatRule,
  Tag,
  Todo,
  When
} from '../core/model/Entities.ets';
import { OrdoEngine, CompletionFeedback } from '../core/store/OrdoEngine.ets';
import { MemoryOrdoStore } from '../core/storage/MemoryStore.ets';
import { KvKeys, OrdoStore } from '../core/storage/OrdoStore.ets';
import { RdbOrdoStore } from '../core/storage/RelationalStore.ets';
import { buildSeedState } from '../core/SeedData.ets';
import { AuthResult, SyncApi } from '../core/sync/SyncApi.ets';
import { NoopRealtimeCallbacks, RealtimeClient } from '../core/sync/RealtimeClient.ets';
import { SyncEngine } from '../core/sync/SyncEngine.ets';
import { AuthTokens, ERR_NETWORK, OrdoApiError, SyncPhase, SyncStatus, WsReminder, errorText, idleStatus, phaseLabel } from '../core/sync/SyncTypes.ets';
import { OrdoSession, OrdoSessionHelper, OrdoSessionStore, SessionAuthResponse, SessionAuthTokens, SessionAuthUser } from '../core/session/OrdoSession.ets';
import { parseNaturalNow, ParsedInput } from '../core/nlp/NaturalDateParser.ets';
import {
  DayGroup,
  HeadingGroup,
  LogbookGroup,
  SidebarCounts,
  UPCOMING_WINDOW_DAYS,
  checklistProgress,
  logbook,
  projectGroups,
  projectProgress,
  sidebarCounts,
  tagCounts,
  upcoming,
  upcomingWindow
} from '../core/query/ListQuery.ets';
import { fmtShortDate, todayISO } from '../core/util/DateUtil.ets';
import { newDeviceId, nowMillis } from '../core/util/Ids.ets';
import { containerKeyOf, sameContainer } from './ReorderMath.ets';
import { RefreshMachine, RefreshTone, REFRESH_HOLD_MS } from './RefreshState.ets';
import { ReminderAgent } from '../core/notify/ReminderAgent.ets';
import { DeepLinkTarget, parseDeepLink } from '../core/deeplink/DeepLink.ets';
import { OrdoColorTokens, OrdoColors, OrdoTheme, ThemeMode } from '../theme/Tokens.ets';

/** 服务器地址是否形如 http(s)://host[:port][/path](只做基本形态校验,真实可用性由 health 决定) */
function isValidHttpUrl(url: string): boolean {
  const u: string = url.trim();
  if (u.indexOf('http://') !== 0 && u.indexOf('https://') !== 0) {
    return false;
  }
  const rest: string = u.indexOf('https://') === 0 ? u.substring(8) : u.substring(7);
  return rest.length > 0 && rest.indexOf(' ') < 0;
}

function isLikelyEmail(email: string): boolean {
  const e: string = email.trim();
  const at: number = e.indexOf('@');
  if (at <= 0 || at === e.length - 1) {
    return false;
  }
  const domain: string = e.substring(at + 1);
  return domain.indexOf('.') > 0 && domain.indexOf(' ') < 0;
}

/** 今天视图需要的三段数据 */
export interface TodaySections {
  events: CalendarEvent[];
  main: Todo[];
  tonight: Todo[];
}

/** Toast 消息 */
export interface ToastState {
  text: string;
  seq: number;
  kind: string;
  /** 提示条上的动作文案(空串 = 普通提示;「撤销」用于左滑删除,04 §6) */
  action: string;
}

export const DEFAULT_BASE_URL: string = 'https://api.ordo.app';
export const DEFAULT_WS_URL: string = 'wss://api.ordo.app';

/**
 * 启动阶段(契约 §7.6.4:启动必须先读会话,无会话 → 登录页)。
 *  - booting  正在读会话/初始化存储(整屏 loading)
 *  - login    未登录:渲染登录页(登录 / 注册 / 以游客身份继续)
 *  - entering 登录成功、数据已就绪,登录页正在播放 160ms 淡出(见 LoginGate)
 *  - ready    主界面
 */
export type AuthPhase = 'booting' | 'login' | 'entering' | 'ready';

@Observed
export class AppStore {
  private static shared: AppStore | null = null;

  static instance(): AppStore {
    let s: AppStore | null = AppStore.shared;
    if (s === null) {
      s = new AppStore();
      AppStore.shared = s;
    }
    return s;
  }

  /* ------------------------------------------------------------ 基础设施 */
  engine: OrdoEngine | null = null;
  /** 当前账号的数据存储(每个 userId 一份,契约 §7.6.3) */
  private ordoStore: OrdoStore | null = null;
  /**
   * 应用级存储:只放会话 / 设备 id / 服务器地址 / 外观。
   * 会话必须先于"用哪个账号目录"被读出来,因此它不能待在账号目录里。
   */
  private metaStore: OrdoStore | null = null;
  api: SyncApi | null = null;
  sync: SyncEngine | null = null;
  private realtime: RealtimeClient | null = null;
  private context: common.UIAbilityContext | null = null;

  /* ------------------------------------------------------------ 身份与会话 */
  /** 启动阶段(视图据此决定渲染登录页还是主界面) */
  authPhase: AuthPhase = 'booting';
  /** 当前会话(契约 §7.6.1);null = 未登录 */
  session: OrdoSession | null = null;
  /** 当前账号的本地数据目录名(`userDataDirName(userId)`,设置页展示) */
  userDir: string = '';

  /* ------------------------------------------------------------ 运行状态 */
  ready: boolean = false;
  storageDegraded: boolean = false;
  changeSeq: number = 0;
  syncStatus: SyncStatus = idleStatus();
  deviceId: string = '';
  /** 当前账号的邮箱(游客为空串);登录页回填与设置页展示用 */
  accountEmail: string = '';
  /** 服务端地址(设置页 / 登录页可改,持久化在应用级 kv) */
  baseUrl: string = DEFAULT_BASE_URL;
  /** 登录/注册/游客请求进行中(按钮防重复提交) */
  loginBusy: boolean = false;
  /** 最近一次登录失败的中文提示(空串表示无错误) */
  loginError: string = '';
  /** 登录页默认停在「注册」页签 */
  loginPrefersRegister: boolean = false;
  /** 登录成功后给登录页播放淡出用的时间戳(0 = 不播放) */
  enterAt: number = 0;
  /**
   * 启动阶段序号。AppStore 是普通类(不是组件),而 @Entry 页面只能用 @StorageLink + @Watch
   * 感知"阶段变了";因此每次切换阶段都往 AppStorage 写一次,Index 据此播放
   * 「登录页淡出 160ms → 主界面淡入 220ms」(§5.1)。
   */
  authPhaseSeq: number = 0;

  /**
   * 刷新控件状态机(04 §5.3):同步中转圈、成功转 success 320ms + 「已同步」1.4s 后回落、
   * 失败转 danger 并常驻「同步失败,点击重试」。
   */
  private refresh: RefreshMachine = new RefreshMachine();
  /** 成功态回落到常态的定时器句柄(-1 = 无) */
  private refreshTimer: number = -1;
  /** 日历事件:设备本地只读数据,不参与同步(契约 §2.8) */
  private localEvents: CalendarEvent[] = [];

  /* --------------------------------------------------- 派生结果缓存(局部刷新优化) */
  /**
   * 派生清单的输入只有「引擎实体 + 少数视图开关」。
   * 缓存以 deriveRev 为版本号:任何写操作、导航或引擎变更都会 invalidateDerived(),
   * 未失效时重复读取直接命中缓存,避免同一次渲染里把 currentTodos()/counts()/
   * todaySections() 反复重算(见 README「派生结果缓存」一节的改前/改后对比)。
   */
  private deriveRev: number = 1;
  private cacheRev: number = 0;
  private cacheToday: string = '';
  private cacheSections: TodaySections | null = null;
  private cacheUpcoming: DayGroup[] | null = null;
  private cacheLogbook: LogbookGroup[] | null = null;
  private cacheCounts: SidebarCounts | null = null;
  private cacheTagCounts: Map<string, number> | null = null;
  private cacheCurrent: Todo[] | null = null;
  private cacheCurrentKey: string = '';

  /* ------------------------------------------------------------ 主题 */
  themeMode: ThemeMode = 'auto';
  systemDark: boolean = false;

  /* ------------------------------------------------------------ 导航 */
  list: ListKind = 'today';
  projectId: string = '';
  areaId: string = '';
  tagName: string = '';
  searchKeyword: string = '';
  showCompleted: boolean = false;

  /* ------------------------------------------------------------ 浮层与选中 */
  selectedTodoId: string = '';
  quickAddOpen: boolean = false;
  quickAddWhen: string = '';
  quickAddProjectId: string = '';
  quickAddHeadingId: string = '';
  /**
   * 快加输入框的"聚焦请求"序号:每次 openQuickAdd 都 +1。
   * 面板首次出现由输入框 onAppear 抢焦点;**已经打开时再点加号**则由该序号变化
   * 再次聚焦(而不是"看着没反应"),软键盘随之弹出。
   */
  quickAddFocusSeq: number = 0;
  scheduleTodoId: string = '';
  scheduleIsDeadline: boolean = false;
  fastFindOpen: boolean = false;
  settingsOpen: boolean = false;
  drawerOpen: boolean = false;
  toast: ToastState = { text: '', seq: 0, kind: 'info', action: '' };
  /** 完成动效:正在播放动画的待办 id */
  animatingTodoId: string = '';
  /** 左滑删除的"可撤销"目标(空串 = 当前没有可撤销的删除) */
  private undoTodoId: string = '';

  /* ------------------------------------------------------------ 生命周期 */

  /**
   * 启动(契约 §7.6.4 四端一致):
   * ```
   * 读 session
   *   ├─ 有且未过期            → 直接进入主界面(后台静默 refresh)
   *   ├─ 有但 accessToken 过期 → 先 refresh;失败 → 登录页(保留 userId 目录)
   *   └─ 无                    → 登录页(必须选择:登录 / 注册 / 游客登录)
   * ```
   * 顺序上有一处必须小心:**会话存在应用级库里**,账号实体存在 `<userId>/` 目录里,
   * 所以先打开应用级库读会话,再按会话里的 userId 打开账号库。
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.applySystemColorMode(context);

    // 1) 应用级存储(会话 / 设备 id / 服务器地址 / 外观)
    let meta: OrdoStore;
    try {
      const metaRdb: RdbOrdoStore = new RdbOrdoStore(context, '', true);
      await metaRdb.init();
      meta = metaRdb;
    } catch (e) {
      console.error('[AppStore] 应用级 RDB 初始化失败,降级为内存存储');
      this.storageDegraded = true;
      meta = new MemoryOrdoStore(undefined, '', true);
      await meta.init();
    }
    this.metaStore = meta;

    // 2) 设备 id(首次安装生成;属于设备而非账号,退出登录也不清)
    let deviceId: string | null = await meta.getKv(KvKeys.DEVICE_ID);
    if (deviceId === null || deviceId.length === 0) {
      deviceId = newDeviceId();
      await meta.setKv(KvKeys.DEVICE_ID, deviceId);
    }
    this.deviceId = deviceId;

    // 3) 外观与服务端地址
    this.themeMode = OrdoTheme.parse(await meta.getKv(KvKeys.THEME_MODE));
    let baseUrl: string | null = await meta.getKv(KvKeys.BASE_URL);
    if (baseUrl === null || baseUrl.length === 0) {
      baseUrl = DEFAULT_BASE_URL;
    }
    this.baseUrl = baseUrl;
    const lastEmail: string | null = await meta.getKv(KvKeys.LAST_EMAIL);
    this.accountEmail = lastEmail === null ? '' : lastEmail;

    // 4) 网络层:登录页也要用它(此时还没有账号,令牌为空)
    const api: SyncApi = new SyncApi(baseUrl, deviceId);
    this.api = api;
    this.realtime = new RealtimeClient(
      this.wsUrlOf(baseUrl),
      deviceId,
      (): string | null => {
        const t = api.getTokens();
        return t === null ? null : t.accessToken;
      },
      new NoopRealtimeCallbacks()
    );

    // 5) 读会话 → 决定去登录页还是主界面
    const session: OrdoSession | null = await new OrdoSessionStore(meta).load();
    this.ready = true;
    if (session === null) {
      this.setAuthPhase('login');
      this.bump();
      return;
    }
    this.accountEmail = session.email === null ? '' : session.email;
    await this.enterSession(session, true);
  }

  /** 是否已完成初始化 */
  isReady(): boolean {
    return this.ready;
  }

  /**
   * 按会话进入某个账号:打开该 userId 的独立数据目录 → 引擎 → 同步,
   * 然后判定是否要写演示数据(§7.6.3:首次登录且服务端无数据时才写)。
   *
   * `atStartup = true` 表示这是冷启动恢复会话:过期就后台静默 refresh,不让用户等。
   */
  private async enterSession(session: OrdoSession, atStartup: boolean): Promise<void> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      this.setAuthPhase('login');
      this.bump();
      return;
    }
    // 目录名一律来自 userDataDirName:任何账号都不可能落到别人的目录(§7.6.3 硬约束)
    const dirName: string = OrdoSessionHelper.userDataDirName(session.userId);
    this.userDir = dirName;

    let store: OrdoStore;
    try {
      const rdb: RdbOrdoStore = new RdbOrdoStore(context, dirName, false);
      await rdb.init();
      store = rdb;
    } catch (e) {
      console.error('[AppStore] 账号 RDB 初始化失败,降级为内存存储');
      this.storageDegraded = true;
      store = new MemoryOrdoStore(undefined, dirName, false);
      await store.init();
    }
    this.ordoStore = store;

    // 令牌落在本账号的 kv 里(同步引擎 start() 从这里恢复;退出登录只清会话令牌,保留实体)
    await store.setKv(KvKeys.ACCESS_TOKEN, session.accessToken);
    await store.setKv(KvKeys.REFRESH_TOKEN, session.refreshToken);

    const engine: OrdoEngine = new OrdoEngine(store);
    this.engine = engine;
    await engine.init(this.deviceId);

    const api: SyncApi | null = this.api;
    const realtime: RealtimeClient | null = this.realtime;
    if (api === null || realtime === null) {
      console.error('[AppStore] 网络层尚未就绪,无法进入账号');
      this.setAuthPhase('login');
      this.bump();
      return;
    }
    api.setTokens({ accessToken: session.accessToken, refreshToken: session.refreshToken, expiresIn: 0 });
    const sync: SyncEngine = new SyncEngine(api, realtime, engine, engine, store);
    this.sync = sync;
    realtime.setCallbacks(sync.buildRealtimeCallbacks());

    engine.addListener((): void => {
      this.invalidateDerived();
      this.bump();
    });
    sync.setListener((s: SyncStatus): void => {
      this.syncStatus = s;
      this.applyRefreshPhase(s.phase);
      this.bump();
    });
    sync.onReminder((r: WsReminder): void => {
      this.onFastlaneReminder(r);
    });

    this.session = session;
    // 日程区块是**设备本地**的只读日历事件(契约 §2.8),不属于任何账号的数据,故每次进入都取本机种子
    this.localEvents = buildSeedState(todayISO()).events;

    await sync.start();
    await this.seedDemoDataIfServerEmpty();
    this.refreshReminders();
    this.invalidateDerived();
    this.bump();

    if (atStartup) {
      if (OrdoSessionHelper.isExpired(session, nowMillis())) {
        // 有但 accessToken 过期 → 先 refresh(见 refreshSessionQuietly 的两种失败分支)
        this.refreshSessionQuietly();
      } else {
        // 有且未过期 → 直接进主界面,后台静默同步一次(§7.6.4)
        this.syncNow();
      }
    }
  }

  /**
   * 首次进入某个账号目录时的演示数据(契约 §7.6.3):
   * 「首次登录某账号且服务端无数据时,才写入演示数据」。
   * 因此顺序必须是**先拉服务端快照,再看本地是否为空**;拉不到(离线)就不写,等下次同步再判定。
   */
  private async seedDemoDataIfServerEmpty(): Promise<void> {
    const store: OrdoStore | null = this.ordoStore;
    const engine: OrdoEngine | null = this.engine;
    const sync: SyncEngine | null = this.sync;
    if (store === null || engine === null || sync === null) {
      return;
    }
    const seeded: string | null = await store.getKv(KvKeys.SEEDED);
    if (seeded === '1') {
      return;
    }
    try {
      await sync.resyncSnapshot();
    } catch (e) {
      // 服务端不可达:此刻无法判断"服务端有没有数据",不写演示数据,下次登录再判定
      return;
    }
    if (engine.todos().length === 0 && engine.projects().length === 0) {
      const seed = buildSeedState(todayISO());
      await engine.persistAll(seed);
      this.localEvents = seed.events;
    }
    await store.setKv(KvKeys.SEEDED, '1');
  }

  /** 登录页淡出播放完毕 → 进入主界面(由 Index 在 160ms 后调用) */
  completeEnter(): void {
    if (this.authPhase === 'entering') {
      this.setAuthPhase('ready');
      this.bump();
    }
  }

  /** 切换启动阶段,并把序号写进 AppStorage(Index 用 @StorageLink + @Watch 消费,见字段注释) */
  private setAuthPhase(phase: AuthPhase): void {
    this.authPhase = phase;
    this.authPhaseSeq = this.authPhaseSeq + 1;
    AppStorage.setOrCreate<number>('ordo.authPhaseSeq', this.authPhaseSeq);
  }

  /* ------------------------------------------------------- 拖拽取消(04 §5.4) */

  /** 是否有一行正处于拖拽中(ListPage 维护;返回键据此优先取消拖拽而不是退出页面) */
  dragActive: boolean = false;
  /** 取消拖拽请求序号:Index 的返回键 +1,ListPage 监听后把行放回原位且不写库 */
  dragCancelSeq: number = 0;

  requestDragCancel(): void {
    this.dragCancelSeq = this.dragCancelSeq + 1;
    this.bump();
  }

  /**
   * 会话失效(refresh 被服务端拒绝):回登录页,**保留 userId 目录**(§7.6.3)。
   * 与 logout() 的区别:这里不主动调 /v1/auth/logout(令牌已经无效)。
   */
  private async forceLogin(reason: string): Promise<void> {
    const meta: OrdoStore | null = this.metaStore;
    if (meta !== null) {
      await new OrdoSessionStore(meta).clear();
    }
    // 内存里的令牌也要清:否则界面已经回到登录页,网络层却还揣着上一个会话的凭据
    const api: SyncApi | null = this.api;
    if (api !== null) {
      api.setTokens(null);
    }
    const sync: SyncEngine | null = this.sync;
    if (sync !== null) {
      sync.stop();
    }
    this.session = null;
    this.engine = null;
    this.sync = null;
    this.ordoStore = null;
    this.userDir = '';
    this.syncStatus = idleStatus();
    this.refresh.reset();
    this.loginError = reason;
    this.setAuthPhase('login');
    this.invalidateDerived();
    this.bump();
  }

  /**
   * 冷启动时的静默续期(§7.6.4「有但 accessToken 过期 → 先 refresh」)。
   * 区分两种失败:
   *  - 网络不可达 → **留在主界面离线可用**(会话不清,目录不动),状态栏走 §5.3 的失败态;
   *  - 服务端拒绝 → 回登录页(保留目录)。
   */
  private async refreshSessionQuietly(): Promise<void> {
    const api: SyncApi | null = this.api;
    if (api === null) {
      return;
    }
    try {
      const tokens: AuthTokens = await api.refresh();
      await this.persistRefreshedTokens(tokens);
      const sync: SyncEngine | null = this.sync;
      if (sync !== null) {
        sync.onTokensUpdated();
      }
      // 续期成功后立刻补一次增量同步,把离线期间的改动推上去
      await this.syncNow();
    } catch (e) {
      const err: OrdoApiError = e as OrdoApiError;
      const code: string = err !== null && err.code !== undefined ? err.code : ERR_NETWORK;
      if (code === ERR_NETWORK) {
        return;
      }
      await this.forceLogin(errorText(code));
    }
  }

  /** refresh 成功:会话(应用级)与令牌(账号级)一起更新,过期时刻按服务端 expiresIn 重算 */
  private async persistRefreshedTokens(tokens: AuthTokens): Promise<void> {
    const meta: OrdoStore | null = this.metaStore;
    const current: OrdoSession | null = this.session;
    if (current !== null) {
      const next: OrdoSession = {
        userId: current.userId,
        email: current.email,
        isGuest: current.isGuest,
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresIn > 0 ? nowMillis() + tokens.expiresIn * 1000 : 0
      };
      this.session = next;
      if (meta !== null) {
        await new OrdoSessionStore(meta).save(next);
      }
    }
    const store: OrdoStore | null = this.ordoStore;
    if (store !== null) {
      await store.setKv(KvKeys.ACCESS_TOKEN, tokens.accessToken);
      await store.setKv(KvKeys.REFRESH_TOKEN, tokens.refreshToken);
    }
  }

  private wsUrlOf(baseUrl: string): string {
    if (baseUrl.indexOf('https://') === 0) {
      return 'wss://' + baseUrl.substring(8) + '/v1/ws';
    }
    if (baseUrl.indexOf('http://') === 0) {
      return 'ws://' + baseUrl.substring(7) + '/v1/ws';
    }
    return DEFAULT_WS_URL + '/v1/ws';
  }

  /** 系统深浅色(跟随系统的依据) */
  applySystemColorMode(context: common.UIAbilityContext): void {
    try {
      // context.config.colorMode 的类型是 ColorMode | undefined(未设置时为空),需要显式兼容
      const mode: ConfigurationConstant.ColorMode | undefined = context.config.colorMode;
      this.systemDark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      this.systemDark = false;
    }
    this.bump();
  }

  isDark(): boolean {
    if (this.themeMode === 'dark') {
      return true;
    }
    if (this.themeMode === 'light') {
      return false;
    }
    return this.systemDark;
  }

  colors(): OrdoColorTokens {
    return OrdoColors.of(this.isDark());
  }

  /** 侧栏主题按钮图标:浅色时提示"切换到深色",反之亦然 */
  themeGlyph(): string {
    return this.isDark() ? '☀' : '☾';
  }

  async cycleTheme(): Promise<void> {
    this.themeMode = OrdoTheme.next(this.themeMode);
    const store: OrdoStore | null = this.ordoStore;
    if (store !== null) {
      await store.setKv(KvKeys.THEME_MODE, this.themeMode);
    }
    this.showToast('外观:' + OrdoTheme.label(this.themeMode));
    this.bump();
  }

  async setTheme(mode: ThemeMode): Promise<void> {
    this.themeMode = mode;
    const store: OrdoStore | null = this.ordoStore;
    if (store !== null) {
      await store.setKv(KvKeys.THEME_MODE, mode);
    }
    this.bump();
  }

  /* ------------------------------------------------------------ 渲染驱动 */

  /** 窗口是否处于窄屏(由 Index 根据 onAreaChange 更新) */
  narrow: boolean = false;

  isNarrow(): boolean {
    return this.narrow;
  }

  /**
   * 打开行内新建(可指定落入的清单/项目/标题)。
   * 面板已经打开时重复调用不是空操作:序号 +1 会让输入框重新聚焦(软键盘弹出),见 QuickAddPanel.focusSeq。
   */
  openQuickAdd(when: string, projectId: string, headingId: string): void {
    this.quickAddOpen = true;
    this.quickAddWhen = when;
    this.quickAddProjectId = projectId;
    this.quickAddHeadingId = headingId;
    this.quickAddFocusSeq = this.quickAddFocusSeq + 1;
    this.bump();
  }

  closeQuickAdd(): void {
    this.quickAddOpen = false;
    this.quickAddWhen = '';
    this.bump();
  }

  /** 打开排期面板(04 §4:排期面板浮层宽 280) */
  openSchedule(todoId: string, isDeadline: boolean): void {
    this.scheduleTodoId = todoId;
    this.scheduleIsDeadline = isDeadline;
    this.bump();
  }

  closeSchedule(): void {
    this.scheduleTodoId = '';
    this.scheduleIsDeadline = false;
    this.bump();
  }

  /** 通知所有 @ObjectLink 视图重新渲染 */
  bump(): void {
    this.changeSeq = this.changeSeq + 1;
  }

  /**
   * 让派生清单缓存失效。任何一个会改变「实体集合或视图开关」的动作都必须调用它:
   *  - 引擎 emit(任何读写落库)
   *  - 导航切换(goList/goProject/…)、showCompleted 变化
   *  - 主题以外的设置变化不影响实体,不需要调用
   * 失效只清标记,不立即重算(惰性重建),因此连续多次失效只付一次重建成本。
   */
  invalidateDerived(): void {
    this.deriveRev = this.deriveRev + 1;
  }

  /** 缓存是否仍然有效(版本号一致且仍是同一天) */
  private cacheValid(): boolean {
    return this.cacheRev === this.deriveRev;
  }

  /** 为一组派生结果打上当前版本号 */
  private stampCache(): void {
    this.cacheRev = this.deriveRev;
    this.cacheToday = todayISO();
  }

  /** 版本号过期(或跨天)时清空全部派生缓存 */
  private ensureCache(): void {
    if (this.cacheValid() && this.cacheToday === todayISO()) {
      return;
    }
    this.cacheSections = null;
    this.cacheUpcoming = null;
    this.cacheLogbook = null;
    this.cacheCounts = null;
    this.cacheTagCounts = null;
    this.cacheCurrent = null;
    this.cacheCurrentKey = '';
  }

  /**
   * 普通提示(无动作)。提示条是单槽位:新提示会顶掉上一条,因此这里同时清掉
   * 「可撤销删除」的目标——界面上已经没有那个"撤销"按钮了,不能让它在后台留着。
   */
  showToast(text: string): void {
    this.undoTodoId = '';
    this.toast = { text: text, seq: this.toast.seq + 1, kind: 'info', action: '' };
    this.bump();
  }

  /* ------------------------------------------------------------ 数据访问 */

  todos(): Todo[] {
    const e: OrdoEngine | null = this.engine;
    return e === null ? [] : e.todos();
  }

  projects(): Project[] {
    const e: OrdoEngine | null = this.engine;
    return e === null ? [] : e.projects();
  }

  areas(): Area[] {
    const e: OrdoEngine | null = this.engine;
    return e === null ? [] : e.areas();
  }

  tags(): Tag[] {
    const e: OrdoEngine | null = this.engine;
    return e === null ? [] : e.tags();
  }

  events(): CalendarEvent[] {
    return this.localEvents;
  }

  findTodo(id: string): Todo | null {
    const e: OrdoEngine | null = this.engine;
    return e === null ? null : e.findTodo(id);
  }

  findProject(id: string): Project | null {
    const e: OrdoEngine | null = this.engine;
    return e === null ? null : e.findProject(id);
  }

  /* ------------------------------------------------------------ 派生查询 */
  /* 全部走缓存:版本未变时直接返回上次结果,不再重算/重排。 */

  counts(): SidebarCounts {
    this.ensureCache();
    const hit: SidebarCounts | null = this.cacheCounts;
    if (hit !== null) {
      return hit;
    }
    const today: string = todayISO();
    const computed: SidebarCounts = sidebarCounts(this.todos(), today, upcomingWindow(today));
    this.cacheCounts = computed;
    this.stampCache();
    return computed;
  }

  tagCountMap(): Map<string, number> {
    this.ensureCache();
    const hit: Map<string, number> | null = this.cacheTagCounts;
    if (hit !== null) {
      return hit;
    }
    const computed: Map<string, number> = tagCounts(this.todos());
    this.cacheTagCounts = computed;
    this.stampCache();
    return computed;
  }

  todaySections(): TodaySections {
    this.ensureCache();
    const hit: TodaySections | null = this.cacheSections;
    if (hit !== null) {
      return hit;
    }
    const all: Todo[] = this.todos();
    const today: string = todayISO();
    const main: Todo[] = [];
    const tonight: Todo[] = [];
    const sorted: Todo[] = todaySorted(all, today);
    for (let i = 0; i < sorted.length; i++) {
      const t: Todo = sorted[i];
      if (t.when === 'evening') {
        tonight.push(t);
      } else {
        main.push(t);
      }
    }
    const sections: TodaySections = { events: this.events(), main: main, tonight: tonight };
    this.cacheSections = sections;
    this.stampCache();
    return sections;
  }

  upcomingGroups(): DayGroup[] {
    this.ensureCache();
    const hit: DayGroup[] | null = this.cacheUpcoming;
    if (hit !== null) {
      return hit;
    }
    const computed: DayGroup[] = upcoming(this.todos(), todayISO(), upcomingWindow(todayISO()));
    this.cacheUpcoming = computed;
    this.stampCache();
    return computed;
  }

  logbookGroups(): LogbookGroup[] {
    this.ensureCache();
    const hit: LogbookGroup[] | null = this.cacheLogbook;
    if (hit !== null) {
      return hit;
    }
    const computed: LogbookGroup[] = logbook(this.todos());
    this.cacheLogbook = computed;
    this.stampCache();
    return computed;
  }

  /** 当前清单的待办(项目/标签/搜索/内置清单统一入口) */
  currentTodos(): Todo[] {
    const key: string = this.listKey();
    this.ensureCache();
    const hit: Todo[] | null = this.cacheCurrent;
    if (hit !== null && this.cacheCurrentKey === key) {
      return hit;
    }
    const computed: Todo[] = this.computeCurrentTodos();
    this.cacheCurrent = computed;
    this.cacheCurrentKey = key;
    this.stampCache();
    return computed;
  }

  /**
   * 清单键:清单类型 + 关键参数,任一变化即视为不同结果集。
   *
   * 视图层也用它做 `LazyForEach` 数据源的缓存键(见 `view/ListPage.ets` 的 `sources`):
   * 每个清单各自持有一份行序列,切回来时不必整表重建,只补差量。
   */
  listKey(): string {
    return this.list + '|' + this.projectId + '|' + this.areaId + '|' + this.tagName + '|' +
      this.searchKeyword + '|' + (this.showCompleted ? '1' : '0');
  }

  private computeCurrentTodos(): Todo[] {
    const all: Todo[] = this.todos();
    if (this.list === 'project') {
      const groups: HeadingGroup[] = this.currentProjectGroups();
      const flat: Todo[] = [];
      for (let i = 0; i < groups.length; i++) {
        const list: Todo[] = groups[i].todos;
        for (let k = 0; k < list.length; k++) {
          flat.push(list[k]);
        }
      }
      return flat;
    }
    if (this.list === 'tag') {
      let out: Todo[] = [];
      for (let i = 0; i < all.length; i++) {
        const t: Todo = all[i];
        if (t.deleted || t.tags.indexOf(this.tagName) < 0) {
          continue;
        }
        if (!this.showCompleted && t.status !== 'open') {
          continue;
        }
        out.push(t);
      }
      return out;
    }
    if (this.list === 'area') {
      return areaTodosOf(all, this.projects(), this.areaId);
    }
    if (this.list === 'search') {
      return searchOf(all, this.searchKeyword);
    }
    if (this.list === 'inbox') {
      return inboxOf(all);
    }
    if (this.list === 'anytime') {
      return whenOf(all, 'anytime');
    }
    if (this.list === 'someday') {
      return whenOf(all, 'someday');
    }
    if (this.list === 'today') {
      const s: TodaySections = this.todaySections();
      const flat: Todo[] = [];
      for (let i = 0; i < s.main.length; i++) {
        flat.push(s.main[i]);
      }
      for (let i = 0; i < s.tonight.length; i++) {
        flat.push(s.tonight[i]);
      }
      return flat;
    }
    if (this.list === 'upcoming') {
      const groups: DayGroup[] = this.upcomingGroups();
      const flat: Todo[] = [];
      for (let i = 0; i < groups.length; i++) {
        const list: Todo[] = groups[i].todos;
        for (let k = 0; k < list.length; k++) {
          flat.push(list[k]);
        }
      }
      return flat;
    }
    return all;
  }

  currentProjectGroups(): HeadingGroup[] {
    const p: Project | null = this.findProject(this.projectId);
    if (p === null) {
      return [];
    }
    return projectGroups(this.todos(), p.headings, this.projectId);
  }

  progressOf(projectId: string): number {
    return projectProgress(this.todos(), projectId);
  }

  /* ------------------------------------------------------------ 标题文案 */

  headerTitle(): string {
    if (this.list === 'inbox') {
      return '收件箱';
    }
    if (this.list === 'today') {
      return '今天';
    }
    if (this.list === 'upcoming') {
      return '计划';
    }
    if (this.list === 'anytime') {
      return '随时';
    }
    if (this.list === 'someday') {
      return '某天';
    }
    if (this.list === 'logbook') {
      return '日志簿';
    }
    if (this.list === 'project') {
      const p: Project | null = this.findProject(this.projectId);
      return p === null ? '项目' : p.name;
    }
    if (this.list === 'area') {
      const e: OrdoEngine | null = this.engine;
      const a: Area | null = e === null ? null : e.findArea(this.areaId);
      return a === null ? '区域' : a.name;
    }
    if (this.list === 'tag') {
      return '#' + this.tagName;
    }
    if (this.list === 'search') {
      return '搜索';
    }
    return '序';
  }

  headerSubtitle(): string {
    if (this.list === 'today') {
      const s: TodaySections = this.todaySections();
      return '今天 · ' + weekdayCnOf(todayISO()) + ' · 日程 ' + s.events.length.toString() + ' 项';
    }
    if (this.list === 'upcoming') {
      return '未来 ' + UPCOMING_WINDOW_DAYS.toString() + ' 天';
    }
    if (this.list === 'logbook') {
      return '已完成与已取消';
    }
    if (this.list === 'project') {
      const p: Project | null = this.findProject(this.projectId);
      if (p === null) {
        return '';
      }
      const percent: number = Math.round(this.progressOf(this.projectId) * 100);
      return '完成度 ' + percent.toString() + '%';
    }
    if (this.list === 'search') {
      return '关键词:' + this.searchKeyword;
    }
    const open: number = countOpen(this.currentTodos());
    return '共 ' + open.toString() + ' 项待完成';
  }

  /* ------------------------------------------------------------ 导航动作 */

  goList(kind: ListKind): void {
    this.list = kind;
    this.projectId = '';
    this.areaId = '';
    this.tagName = '';
    this.searchKeyword = '';
    this.selectedTodoId = '';
    this.drawerOpen = false;
    this.invalidateDerived();
    this.bump();
  }

  goProject(projectId: string): void {
    this.list = 'project';
    this.projectId = projectId;
    this.tagName = '';
    this.searchKeyword = '';
    this.selectedTodoId = '';
    this.drawerOpen = false;
    this.invalidateDerived();
    this.bump();
  }

  goArea(areaId: string): void {
    this.list = 'area';
    this.areaId = areaId;
    this.projectId = '';
    this.tagName = '';
    this.selectedTodoId = '';
    this.drawerOpen = false;
    this.invalidateDerived();
    this.bump();
  }

  goTag(name: string): void {
    this.list = 'tag';
    this.tagName = name;
    this.projectId = '';
    this.areaId = '';
    this.showCompleted = false;
    this.selectedTodoId = '';
    this.drawerOpen = false;
    this.invalidateDerived();
    this.bump();
  }

  goSearch(keyword: string): void {
    this.list = 'search';
    this.searchKeyword = keyword;
    this.fastFindOpen = false;
    this.selectedTodoId = '';
    this.invalidateDerived();
    this.bump();
  }

  /** 应用深链(ordo://) */
  applyDeepLink(uri: string): void {
    const target: DeepLinkTarget = parseDeepLink(uri);
    if (target.kind === 'list') {
      const kind: ListKind = target.value as ListKind;
      this.goList(kind);
      return;
    }
    if (target.kind === 'project') {
      this.goProject(target.value);
      return;
    }
    if (target.kind === 'tag') {
      this.goTag(target.value);
      return;
    }
    if (target.kind === 'todo') {
      const t: Todo | null = this.findTodo(target.value);
      if (t !== null) {
        this.openProjectOrList(t);
        this.selectedTodoId = t.id;
        this.bump();
      }
      return;
    }
    if (target.kind === 'add') {
      // 与加号按钮走同一条链路:除重置目标外还会请求输入框聚焦(这是"点了有反应"的判据)
      this.openQuickAdd('', '', '');
    }
  }

  private openProjectOrList(t: Todo): void {
    if (t.projectId !== null) {
      this.goProject(t.projectId);
    } else if (t.areaId !== null) {
      this.goArea(t.areaId);
    } else if (t.when === 'inbox') {
      this.goList('inbox');
    } else {
      this.goList('today');
    }
  }

  /* ------------------------------------------------------------ 写入动作 */

  createTodoFromInput(raw: string): Todo | null {
    const e: OrdoEngine | null = this.engine;
    if (e === null || raw.trim().length === 0) {
      return null;
    }
    const projectId: string | null = this.resolveQuickAddProject();
    const t: Todo | null = e.createTodo({
      raw: raw,
      projectId: projectId,
      areaId: this.resolveQuickAddArea(),
      headingId: this.quickAddHeadingId.length > 0 ? this.quickAddHeadingId : null,
      when: this.quickAddWhen.length > 0 ? (this.quickAddWhen as When) : null
    });
    if (t !== null) {
      this.afterWrite(t);
    }
    return t;
  }

  private resolveQuickAddProject(): string | null {
    if (this.quickAddProjectId.length > 0) {
      return this.quickAddProjectId;
    }
    if (this.list === 'project') {
      return this.projectId;
    }
    return null;
  }

  private resolveQuickAddArea(): string | null {
    if (this.list === 'area') {
      return this.areaId;
    }
    return null;
  }

  toggleDone(id: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    const before: Todo | null = e.findTodo(id);
    if (before === null) {
      return;
    }
    this.animatingTodoId = id;
    const result: CompletionFeedback = e.toggleDone(id);
    this.animatingTodoId = '';
    if (result.repeatCreated) {
      this.showToast('已完成 · 已生成下一次重复');
    } else if (result.todo !== null && result.todo.status === 'done') {
      this.showToast('已完成');
    }
    this.afterWrite(result.todo);
  }

  cancelTodo(id: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.cancelTodo(id);
    this.showToast('已取消');
    this.afterWrite(e.findTodo(id));
  }

  restoreTodo(id: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.restoreTodo(id);
    this.showToast('已恢复');
    this.afterWrite(e.findTodo(id));
  }

  deleteTodo(id: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.deleteTodo(id);
    if (this.selectedTodoId === id) {
      this.selectedTodoId = '';
    }
    ReminderAgent.cancel(id);
    this.showToast('已删除');
    this.afterWrite(null);
  }

  /**
   * 左滑删除 + 可撤销(04 §6「左滑删除」;§4 的提示条是底部 pill,这里在提示条上挂一个"撤销"动作)。
   *
   * 删除本身仍是契约 §3 的软删除(`deleted=true` + 墓碑),`undoDelete()` 只是把 `deleted` 复位,
   * 因此撤销产出的是**同一实体的另一次 LWW 更新**,不会留下"删除 op + 新建 op"两条互相打架的记录。
   * 契约与 04 号文档都没写"二次确认"还是"可撤销",这里按可撤销实现(更轻、可恢复,不会打断手势)。
   */
  deleteTodoWithUndo(id: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    const t: Todo | null = e.findTodo(id);
    if (t === null || t.deleted) {
      return;
    }
    const title: string = t.title.length > 12 ? t.title.substring(0, 12) + '…' : t.title;
    e.deleteTodo(id);
    if (this.selectedTodoId === id) {
      this.selectedTodoId = '';
    }
    ReminderAgent.cancel(id);
    this.undoTodoId = id;
    this.toast = {
      text: '已删除「' + title + '」',
      seq: this.toast.seq + 1,
      kind: 'info',
      action: '撤销'
    };
    this.afterWrite(null);
  }

  /** 撤销上一次左滑删除(提示条上的"撤销") */
  undoDelete(): void {
    const e: OrdoEngine | null = this.engine;
    const id: string = this.undoTodoId;
    this.undoTodoId = '';
    if (e === null || id.length === 0) {
      return;
    }
    if (!e.restoreDeletedTodo(id)) {
      this.showToast('这条待办已无法恢复');
      return;
    }
    const t: Todo | null = e.findTodo(id);
    if (t !== null && t.reminder !== null) {
      ReminderAgent.refresh(t);
    }
    this.showToast('已恢复');
    this.afterWrite(t);
  }

  /** 当前提示条上是否有可撤销的删除 */
  hasUndo(): boolean {
    return this.undoTodoId.length > 0;
  }

  /**
   * 拖拽排序(04 §6「长按拖拽」):把**同一容器内的完整可见序列**整段提交给核心。
   *
   * 两道闸门(与 iOS `AppEnvironment.reorderTodos(ids:)` 一致,缺一不可):
   *  1. 每个 id 都能在本地找到、至少 2 条;
   *  2. 所有 id 同容器——`order` 只在 `(when, projectId, headingId)` 内连续(见 `OrdoEngine.nextOrder`),
   *     跨分区/跨项目拖动会写出互相竞争的 order,这里直接拒绝并提示。
   *
   * 提交的是**完整序列**而不是"被拖的那一条":核心的语义是 `ids[i].order = i`,
   * 它不知道清单里被过滤掉了哪些条目,残缺序列会把未提交的条目挤到末尾。
   *
   * @returns 是否受理(未受理时不动数据)
   */
  reorderTodos(ids: string[]): boolean {
    const e: OrdoEngine | null = this.engine;
    if (e === null || ids.length < 2) {
      return false;
    }
    const containers: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const t: Todo | null = e.findTodo(ids[i]);
      if (t === null) {
        return false;
      }
      containers.push(containerKeyOf(t));
    }
    if (!sameContainer(containers)) {
      this.showToast('手动排序只在同一分区/项目内生效');
      return false;
    }
    if (e.reorderTodos(ids) === 0) {
      return false;
    }
    this.afterWrite(null);
    return true;
  }

  setSelected(id: string): void {
    this.selectedTodoId = this.selectedTodoId === id ? '' : id;
    this.bump();
  }

  /* 详情卡片动作(全部转发到引擎,并触发同步与提醒校准) */

  setTodoTitle(id: string, title: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.setTodoTitle(id, title);
    this.afterWrite(e.findTodo(id));
  }

  setTodoNote(id: string, note: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.setTodoNote(id, note);
    this.afterWrite(e.findTodo(id));
  }

  setWhen(id: string, when: string, date: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.setWhen(id, when as When, date.length > 0 ? date : null);
    this.afterWrite(e.findTodo(id));
  }

  setDeadline(id: string, date: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.setDeadline(id, date.length > 0 ? date : null);
    this.afterWrite(e.findTodo(id));
  }

  setReminder(id: string, reminder: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.setReminder(id, reminder.length > 0 ? reminder : null);
    const t: Todo | null = e.findTodo(id);
    if (t !== null) {
      ReminderAgent.refresh(t);
    }
    this.afterWrite(t);
  }

  addTag(id: string, name: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.addTagToTodo(id, name);
    this.afterWrite(e.findTodo(id));
  }

  removeTag(id: string, name: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.removeTagFromTodo(id, name);
    this.afterWrite(e.findTodo(id));
  }

  toggleChecklistItem(todoId: string, itemId: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.toggleChecklistItem(todoId, itemId);
    this.afterWrite(e.findTodo(todoId));
  }

  addChecklistItem(todoId: string, title: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.addChecklistItem(todoId, title);
    this.afterWrite(e.findTodo(todoId));
  }

  removeChecklistItem(todoId: string, itemId: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.removeChecklistItem(todoId, itemId);
    this.afterWrite(e.findTodo(todoId));
  }

  moveTodo(id: string, projectId: string, areaId: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.moveTodo(id, projectId.length > 0 ? projectId : null, areaId.length > 0 ? areaId : null, null);
    this.showToast('已移动');
    this.afterWrite(e.findTodo(id));
  }

  setRepeat(id: string, freq: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    if (freq.length === 0) {
      e.setTodoRepeat(id, null);
    } else {
      const rule: RepeatRule = { freq: freq as RepeatFreq, interval: 1, mode: 'fixed' };
      e.setTodoRepeat(id, rule);
    }
    this.afterWrite(e.findTodo(id));
  }

  duplicateTodo(id: string): Todo | null {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return null;
    }
    const src: Todo | null = e.findTodo(id);
    if (src === null) {
      return null;
    }
    const copy: Todo | null = e.createTodo({
      raw: src.title,
      projectId: src.projectId,
      areaId: src.areaId,
      headingId: src.headingId,
      when: src.when
    });
    if (copy !== null) {
      e.setTodoNote(copy.id, src.note);
      for (let i = 0; i < src.tags.length; i++) {
        e.addTagToTodo(copy.id, src.tags[i]);
      }
      this.showToast('已复制');
      this.afterWrite(copy);
    }
    return copy;
  }

  /** 循环切换重复规则:不重复 → 每天 → 每周 → 每月 → 每年 */
  cycleRepeat(id: string): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    let next: string = 'daily';
    if (t.repeat === null) {
      next = 'daily';
    } else if (t.repeat.freq === 'daily') {
      next = 'weekly';
    } else if (t.repeat.freq === 'weekly') {
      next = 'monthly';
    } else if (t.repeat.freq === 'monthly') {
      next = 'yearly';
    } else {
      next = '';
    }
    this.setRepeat(id, next);
  }

  /** 依次切换到下一个项目(无项目 → 各项目 → 无项目),避免复杂的移动弹层 */
  moveToNextProject(id: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    const open: Project[] = [];
    const list: Project[] = e.projects();
    for (let i = 0; i < list.length; i++) {
      if (!list[i].deleted && list[i].status === 'open') {
        open.push(list[i]);
      }
    }
    const t: Todo | null = e.findTodo(id);
    if (t === null) {
      return;
    }
    if (t.projectId === null) {
      if (open.length === 0) {
        this.showToast('还没有项目,先用快加号新建一个');
        return;
      }
      this.moveTodo(id, open[0].id, '');
      return;
    }
    let idx: number = -1;
    for (let i = 0; i < open.length; i++) {
      if (open[i].id === t.projectId) {
        idx = i;
        break;
      }
    }
    if (idx < 0 || idx + 1 >= open.length) {
      e.moveTodo(id, null, null, null);
      this.showToast('已移出项目');
      this.afterWrite(e.findTodo(id));
      return;
    }
    this.moveTodo(id, open[idx + 1].id, '');
  }

  /* ------------------------------------------------------------ 项目/区域 */

  createProject(name: string, areaId: string): Project | null {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return null;
    }
    const p: Project = e.createProject(name, areaId.length > 0 ? areaId : null);
    this.showToast('已新建项目:' + p.name);
    this.afterWrite(null);
    return p;
  }

  createArea(name: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.createArea(name, '#5B5BD6');
    this.showToast('已新建区域:' + name);
    this.afterWrite(null);
  }

  addHeading(projectId: string, name: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.addHeading(projectId, name);
    this.afterWrite(null);
  }

  toggleHeading(headingId: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    e.toggleHeadingCollapsed(headingId);
    this.bump();
  }

  completeProject(id: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    // 契约 §2.2 v1.1:标题未归档不再阻塞完成;提示语必须与引擎语义一致
    const p: Project | null = e.findProject(id);
    if (p !== null && p.status === 'done') {
      this.showToast('项目已经完成了');
      return;
    }
    if (e.completeProject(id)) {
      this.showToast('项目已完成,未归档标题已自动归档');
    } else {
      this.showToast('项目下还有未完成的待办');
    }
    this.afterWrite(null);
  }

  completeHeading(headingId: string): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    if (e.archiveHeading(headingId)) {
      this.showToast('标题已归档');
    } else {
      this.showToast('该标题下还有未完成的待办');
    }
    this.afterWrite(null);
  }

  /** 恢复内置示例数据(设置页入口;二次确认由 UI 层负责) */
  async resetToSeedData(): Promise<void> {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    const seed = buildSeedState(todayISO());
    await e.persistAll(seed);
    this.localEvents = seed.events;
    ReminderAgent.cancelAll();
    this.invalidateDerived();
    this.showToast('已恢复示例数据');
    this.bump();
  }

  /* ------------------------------------------------------------ 账号与会话 */

  /** 登录页默认页签(由"还没有账号?注册"等入口指定) */
  setLoginPrefersRegister(prefer: boolean): void {
    this.loginPrefersRegister = prefer;
    this.bump();
  }

  /**
   * 是否已登录。判据是**会话**(§7.6.1),不是"内存里有没有令牌":
   * 冷启动时令牌可能在 refresh 之前还没装好,但会话已经在手上。
   */
  isSignedIn(): boolean {
    return this.session !== null;
  }

  isGuest(): boolean {
    const s: OrdoSession | null = this.session;
    return s !== null && s.isGuest;
  }

  /** 展示名:正式账号用邮箱,游客用「游客」(与共享核心 displayName() 同语义) */
  accountText(): string {
    const s: OrdoSession | null = this.session;
    if (s === null) {
      return this.accountEmail.length > 0 ? this.accountEmail + '(登录已失效)' : '未登录';
    }
    return OrdoSessionHelper.displayName(s);
  }

  /** 账号副标题:账号类型 + userId(设置页展示,便于核对"到底进的哪个账号") */
  accountDetailText(): string {
    const s: OrdoSession | null = this.session;
    if (s === null) {
      return '—';
    }
    const kind: string = s.isGuest ? '游客账号(无邮箱口令,同样参与同步)' : '正式账号';
    return kind + ' · userId ' + s.userId;
  }

  /** 当前账号的本地数据目录名(§7.6.3) */
  userDirText(): string {
    return this.userDir.length === 0 ? '—' : this.userDir;
  }

  /** 当前账号库文件的完整沙箱路径(证明两个账号不会共用一个目录) */
  dataPathText(): string {
    const store: OrdoStore | null = this.ordoStore;
    if (store === null) {
      return '—';
    }
    return store.pathText();
  }

  /** 当前服务端地址(设置页展示) */
  serverText(): string {
    return this.baseUrl;
  }

  /**
   * 修改服务端地址:写应用级 kv → 换掉 SyncApi/实时通道的地址 → 触发一次同步探活。
   * 地址不合法时不改任何状态,直接返回 false,由 UI 提示。
   */
  async setBaseUrl(url: string): Promise<boolean> {
    const clean: string = url.trim();
    if (!isValidHttpUrl(clean)) {
      this.showToast('服务器地址需以 http:// 或 https:// 开头');
      return false;
    }
    if (clean === this.baseUrl) {
      return true;
    }
    this.baseUrl = clean;
    const store: OrdoStore | null = this.metaStore;
    if (store !== null) {
      await store.setKv(KvKeys.BASE_URL, clean);
    }
    const api: SyncApi | null = this.api;
    if (api !== null) {
      api.setBaseUrl(clean);
    }
    const realtime: RealtimeClient | null = this.realtime;
    if (realtime !== null) {
      realtime.setUrl(this.wsUrlOf(clean));
    }
    this.invalidateDerived();
    this.showToast('服务器地址已更新');
    this.bump();
    // 按新地址重新握手(重连实时通道 + 一次增量同步探活)
    const sync: SyncEngine | null = this.sync;
    if (sync !== null) {
      await sync.restart();
    }
    return true;
  }

  /**
   * 登录(契约 §7.4 POST /v1/auth/login)。
   * 成功:写会话 → 打开该 userId 的独立目录 → 首次快照 → 进入主界面。
   * 失败:返回 false,loginError 已是中文提示(错误码 → errorText())。
   */
  async login(email: string, password: string): Promise<boolean> {
    return await this.authenticate('login', email, password);
  }

  /** 注册(契约 §7.4 POST /v1/auth/register) */
  async register(email: string, password: string): Promise<boolean> {
    return await this.authenticate('register', email, password);
  }

  /**
   * 游客登录(契约 §7.6.2 POST /v1/auth/guest)。
   * **不是离线模式**:同样注册匿名账号、拿到正常令牌、数据同样入库与同步;
   * 唯一的区别是没有邮箱口令、`isGuest = true`。因此它与正式登录走**完全相同**的后续流程。
   */
  async continueAsGuest(): Promise<boolean> {
    return await this.authenticate('guest', '', '');
  }

  private async authenticate(kind: string, email: string, password: string): Promise<boolean> {
    const api: SyncApi | null = this.api;
    if (api === null) {
      this.loginError = '应用尚未初始化完成,请稍后重试';
      this.bump();
      return false;
    }
    const isGuest: boolean = kind === 'guest';
    const mail: string = isGuest ? '' : email.trim();
    if (!isGuest && !isLikelyEmail(mail)) {
      this.loginError = '请输入有效的邮箱地址';
      this.bump();
      return false;
    }
    if (!isGuest && password.length < 6) {
      this.loginError = '口令至少 6 位';
      this.bump();
      return false;
    }
    this.loginBusy = true;
    this.loginError = '';
    this.bump();
    try {
      let result: AuthResult;
      if (isGuest) {
        result = await api.guest(this.deviceId, this.deviceId, 'harmony');
      } else if (kind === 'register') {
        result = await api.register(mail, password, this.deviceId);
      } else {
        result = await api.login(mail, password, this.deviceId);
      }
      await this.adoptSession(result);
      this.loginBusy = false;
      this.showToast(isGuest ? '已以游客身份登录,同样会同步' : (kind === 'register' ? '注册成功,开始同步' : '已登录'));
      this.bump();
      return true;
    } catch (e) {
      this.loginBusy = false;
      const err: OrdoApiError = e as OrdoApiError;
      if (err !== null && err.code !== undefined && err.code.length > 0) {
        this.loginError = errorText(err.code);
      } else {
        this.loginError = errorText(ERR_NETWORK);
      }
      this.bump();
      return false;
    }
  }

  /**
   * 认证成功:构造会话 → 落盘(应用级)→ 打开该账号的目录并接入同步。
   * `authPhase` 停在 `entering`:由登录页播放 160ms 淡出后调用 completeEnter() 进主界面(§5.1)。
   */
  private async adoptSession(result: AuthResult): Promise<void> {
    // ArkTS 不支持结构化类型:逐字段显式搬运,不能把 AuthUser 直接当 SessionAuthUser 用
    const user: SessionAuthUser = {
      id: result.user.id,
      email: result.user.email,
      isGuest: result.user.isGuest
    };
    const tokens: SessionAuthTokens = {
      accessToken: result.tokens.accessToken,
      refreshToken: result.tokens.refreshToken,
      expiresIn: result.tokens.expiresIn
    };
    const response: SessionAuthResponse = { user: user, tokens: tokens };
    const session: OrdoSession = OrdoSessionHelper.from(response, nowMillis());
    if (session.userId.length === 0) {
      this.loginError = '服务端未返回 userId,无法建立本地数据目录';
      return;
    }
    const meta: OrdoStore | null = this.metaStore;
    if (meta !== null) {
      await new OrdoSessionStore(meta).save(session);
      // 只记邮箱做回填,不记令牌:会话本身已经有令牌了
      await meta.setKv(KvKeys.LAST_EMAIL, session.email === null ? '' : session.email);
    }
    this.accountEmail = session.email === null ? '' : session.email;
    await this.enterSession(session, false);
    this.setAuthPhase('entering');
    this.enterAt = nowMillis();
    this.bump();
  }

  /**
   * 游客升级为正式账号(契约 §7.6.2 POST /v1/auth/upgrade):
   * **userId 不变、数据不变**,只把邮箱口令补上,因此本地目录也不需要换。
   */
  async upgradeGuest(email: string, password: string): Promise<boolean> {
    const api: SyncApi | null = this.api;
    const current: OrdoSession | null = this.session;
    if (api === null || current === null) {
      this.loginError = '当前没有可升级的会话';
      this.bump();
      return false;
    }
    const mail: string = email.trim();
    if (!isLikelyEmail(mail)) {
      this.loginError = '请输入有效的邮箱地址';
      this.bump();
      return false;
    }
    if (password.length < 6) {
      this.loginError = '口令至少 6 位';
      this.bump();
      return false;
    }
    this.loginBusy = true;
    this.loginError = '';
    this.bump();
    try {
      const user = await api.upgrade(mail, password);
      const next: OrdoSession = {
        userId: current.userId,
        email: user.email.length > 0 ? user.email : mail,
        isGuest: false,
        accessToken: current.accessToken,
        refreshToken: current.refreshToken,
        expiresAt: current.expiresAt
      };
      this.session = next;
      this.accountEmail = next.email === null ? '' : next.email;
      const meta: OrdoStore | null = this.metaStore;
      if (meta !== null) {
        await new OrdoSessionStore(meta).save(next);
        await meta.setKv(KvKeys.LAST_EMAIL, this.accountEmail);
      }
      this.loginBusy = false;
      this.showToast('已升级为正式账号,数据保持不变');
      this.bump();
      return true;
    } catch (e) {
      this.loginBusy = false;
      const err: OrdoApiError = e as OrdoApiError;
      this.loginError = err !== null && err.code !== undefined && err.code.length > 0
        ? errorText(err.code)
        : errorText(ERR_NETWORK);
      this.bump();
      return false;
    }
  }

  /**
   * 退出登录(契约 §7.6.3):**只清会话**,该 userId 的本地目录与目录内的数据一律保留,
   * 下次同一账号登录时数据仍在(离线可用,联网后增量同步)。
   */
  async logout(): Promise<void> {
    const api: SyncApi | null = this.api;
    if (api !== null) {
      await api.logout();
    }
    const store: OrdoStore | null = this.ordoStore;
    if (store !== null) {
      // 令牌属于会话凭据,清掉;实体 / outbox / tombstones 全部保留
      await store.removeKv(KvKeys.ACCESS_TOKEN);
      await store.removeKv(KvKeys.REFRESH_TOKEN);
    }
    const meta: OrdoStore | null = this.metaStore;
    if (meta !== null) {
      await new OrdoSessionStore(meta).clear();
      await meta.setKv(KvKeys.LAST_EMAIL, this.accountEmail);
    }
    const sync: SyncEngine | null = this.sync;
    if (sync !== null) {
      sync.stop();
    }
    // 上一个账号的提醒不该在下一个人登录后弹出来
    ReminderAgent.cancelAll();
    this.session = null;
    this.engine = null;
    this.sync = null;
    this.ordoStore = null;
    this.localEvents = [];
    this.userDir = '';
    this.syncStatus = idleStatus();
    this.refresh.reset();
    this.loginError = '';
    this.loginPrefersRegister = false;
    this.setAuthPhase('login');
    this.invalidateDerived();
    this.showToast('已退出登录,本地数据仍保留');
    this.bump();
  }

  /* ------------------------------------------------------------ 同步动作 */

  private afterWrite(t: Todo | null): void {
    const sync: SyncEngine | null = this.sync;
    if (sync !== null) {
      sync.enqueueAndSync();
    }
    if (t !== null && t.reminder !== null) {
      ReminderAgent.refresh(t);
    }
    // 只有实体集合变化才作废派生缓存;纯 UI 浮层开关(选中/浮层开合)不受影响
    this.invalidateDerived();
    this.bump();
  }

  private refreshReminders(): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    ReminderAgent.syncAll(e.todos());
  }

  /** Fastlane 提醒到达(契约 §7.5) */
  private onFastlaneReminder(r: WsReminder): void {
    const e: OrdoEngine | null = this.engine;
    if (e === null) {
      return;
    }
    const t: Todo | null = e.findTodo(r.todoId);
    if (t !== null) {
      ReminderAgent.refresh(t);
    }
    this.showToast('提醒:' + r.title);
  }

  async syncNow(): Promise<void> {
    const sync: SyncEngine | null = this.sync;
    if (sync === null) {
      return;
    }
    await sync.syncNow();
    this.bump();
  }

  /* ------------------------------------------------------------ 刷新控件(04 §5.3) */

  /**
   * 同步引擎状态变化 → 刷新控件状态。
   * 成功态要在 1.4s 后自动回落到常态:这里排一个定时器,到点调 tick() 并按需 bump()。
   */
  private applyRefreshPhase(phase: SyncPhase): void {
    this.refresh.applySyncPhase(phase, nowMillis());
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.refresh.getPhase() === 'success') {
      this.refreshTimer = setTimeout((): void => {
        this.refreshTimer = -1;
        if (this.refresh.tick(nowMillis())) {
          this.bump();
        }
      }, REFRESH_HOLD_MS);
    }
  }

  /** 状态栏文案:同步中… / 已同步 / 同步失败,点击重试 */
  refreshLabel(): string {
    return this.refresh.label();
  }

  /** 图标与文字色调:normal / success / danger */
  refreshTone(): RefreshTone {
    return this.refresh.tone();
  }

  /** 是否连续旋转(同步中) */
  refreshSpinning(): boolean {
    return this.refresh.isSpinning();
  }

  /** 是否可点击(同步中禁用;成功后 1.4s 内防抖禁用) */
  refreshEnabled(): boolean {
    return this.refresh.canTap(nowMillis());
  }

  /** 无障碍朗读文案(§8:状态不只靠颜色表达) */
  refreshA11y(): string {
    return this.refresh.accessibilityText();
  }

  /** 点击刷新控件(或 Ctrl+R):立刻转圈,再触发一次同步 */
  async tapRefresh(): Promise<void> {
    if (!this.refresh.canTap(nowMillis())) {
      return;
    }
    this.refresh.beginManual(nowMillis());
    this.bump();
    await this.syncNow();
  }

  syncText(): string {
    return phaseLabel(this.syncStatus.phase);
  }

  /** 待推送条数(状态栏展示) */
  pendingText(): string {
    const n: number = this.syncStatus.pendingCount;
    if (n <= 0) {
      return '';
    }
    return '· 待同步 ' + n.toString();
  }

  /** 长度上限提醒(契约 §7.4:单次 push ≤ 500) */
  pushBudget(): number {
    return MAX_PUSH_OPS;
  }

  /* ------------------------------------------------------------ 快找 */

  /** 快找结果:清单 + 项目 + 标签 + 待办 */
  fastFind(query: string): Todo[] {
    const keyword: string = query.trim();
    if (keyword.length === 0) {
      return [];
    }
    return searchOf(this.todos(), keyword);
  }

  parsedPreview(raw: string): ParsedInput {
    return parseNaturalNow(raw);
  }

  /** 设置页展示用 */
  storageText(): string {
    return this.storageDegraded ? '内存模式(未持久化)' : 'RelationalStore(已持久化)';
  }

  deviceText(): string {
    return this.deviceId;
  }

  /** 统计文案(状态栏) */
  statsText(): string {
    const e: OrdoEngine | null = this.engine;
    return e === null ? '' : e.stats();
  }

  /** 清单项进度文案 */
  checklistText(t: Todo): string {
    return checklistProgress(t.checklist);
  }

  /** 格式化日期用于展示 */
  prettyDate(iso: string): string {
    return fmtShortDate(iso);
  }
}

/** 实时回调占位已由 RealtimeClient.NoopRealtimeCallbacks 提供 */

/* ------------------------------------------------------------------ 无状态工具 */

function countOpen(list: Todo[]): number {
  let n: number = 0;
  for (let i = 0; i < list.length; i++) {
    if (list[i].status === 'open') {
      n++;
    }
  }
  return n;
}

function inboxOf(all: Todo[]): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < all.length; i++) {
    const t: Todo = all[i];
    if (!t.deleted && t.status === 'open' && t.when === 'inbox') {
      out.push(t);
    }
  }
  out.sort((a: Todo, b: Todo): number => a.order - b.order);
  return out;
}

function whenOf(all: Todo[], when: string): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < all.length; i++) {
    const t: Todo = all[i];
    if (!t.deleted && t.status === 'open' && t.when === when) {
      out.push(t);
    }
  }
  out.sort((a: Todo, b: Todo): number => a.order - b.order);
  return out;
}

function areaTodosOf(all: Todo[], projects: Project[], areaId: string): Todo[] {
  const projectIds: string[] = [];
  for (let i = 0; i < projects.length; i++) {
    if (projects[i].areaId === areaId && !projects[i].deleted) {
      projectIds.push(projects[i].id);
    }
  }
  const out: Todo[] = [];
  for (let i = 0; i < all.length; i++) {
    const t: Todo = all[i];
    if (t.deleted || t.status !== 'open') {
      continue;
    }
    if (t.areaId === areaId || (t.projectId !== null && projectIds.indexOf(t.projectId) >= 0)) {
      out.push(t);
    }
  }
  out.sort((a: Todo, b: Todo): number => a.order - b.order);
  return out;
}

function searchOf(all: Todo[], keyword: string): Todo[] {
  const key: string = keyword.trim().toLowerCase();
  if (key.length === 0) {
    return [];
  }
  const out: Todo[] = [];
  for (let i = 0; i < all.length; i++) {
    const t: Todo = all[i];
    if (t.deleted) {
      continue;
    }
    if (t.title.toLowerCase().indexOf(key) >= 0 || t.note.toLowerCase().indexOf(key) >= 0) {
      out.push(t);
    }
  }
  out.sort((a: Todo, b: Todo): number => {
    const ao: number = a.status === 'open' ? 0 : 1;
    const bo: number = b.status === 'open' ? 0 : 1;
    if (ao !== bo) {
      return ao - bo;
    }
    return b.updatedAt - a.updatedAt;
  });
  return out;
}

function todaySorted(all: Todo[], today: string): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < all.length; i++) {
    const t: Todo = all[i];
    if (t.deleted || t.status !== 'open') {
      continue;
    }
    const byWhen: boolean = t.when === 'today' || t.when === 'evening';
    const byDate: boolean = t.when === 'date' && t.date !== null && t.date <= today;
    const byDeadline: boolean = t.deadline !== null && t.deadline <= today;
    if (byWhen || byDate || byDeadline) {
      out.push(t);
    }
  }
  out.sort((a: Todo, b: Todo): number => {
    const aOver: number = a.deadline !== null && a.deadline < today ? 0 : 1;
    const bOver: number = b.deadline !== null && b.deadline < today ? 0 : 1;
    if (aOver !== bOver) {
      return aOver - bOver;
    }
    if (a.reminder !== null && b.reminder !== null && a.reminder !== b.reminder) {
      return a.reminder < b.reminder ? -1 : 1;
    }
    return a.order - b.order;
  });
  return out;
}

function weekdayCnOf(iso: string): string {
  const names: string[] = ['日', '一', '二', '三', '四', '五', '六'];
  const y: number = parseInt(iso.substring(0, 4), 10);
  const m: number = parseInt(iso.substring(5, 7), 10);
  const d: number = parseInt(iso.substring(8, 10), 10);
  const date: Date = new Date(y, m - 1, d);
  return '周' + names[date.getDay()];
}
