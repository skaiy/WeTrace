import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../providers/app_state.dart';
import '../models/chat_session.dart';
import '../models/message.dart';
import '../widgets/chat_session_item.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_loading_shimmer.dart';
import '../widgets/common/shimmer_loading.dart';
import '../utils/string_utils.dart';
import '../services/logger_service.dart';
import '../services/database_service.dart';

/// 聊天记录页面
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  static const int _initialMessageBatch = 30; // 初始加载数量
  static const int _loadMoreBatch = 50; // 分批加载更多
  static const double _loadTriggerDistance = 200.0;
  static const double _prefetchTriggerDistance = 500.0;

  ChatSession? _selectedSession;
  List<ChatSession> _sessions = [];
  List<ChatSession> _filteredSessions = []; // 搜索过滤后的会话列表
  List<Message> _messages = [];

  String? _myAvatarUrl; // 我的头像
  bool _isLoadingSessions = false;
  bool _isLoadingMessages = false;
  bool _isLoadingMoreMessages = false;
  bool _hasMoreMessages = true;
  int _currentOffset = 0;
  late ScrollController _scrollController;
  // 群聊成员姓名缓存（username -> displayName）
  Map<String, String> _senderDisplayNames = {};
  final Set<String> _messageKeys = {};
  late AnimationController _refreshController;
  DateTime? _lastInitialLoadTime;
  bool _prefetchScheduled = false;
  bool _isRealtimeRefreshing = false;
  Future<void>? _realtimeRefreshFuture;
  bool _realtimeRefreshQueued = false;
  int _realtimeTick = 0;
  bool _isAutoConnecting = false;
  bool _hasAttemptedRefreshAfterConnect = false;
  bool _autoLoadScheduled = false;
  Timer? _searchDebounce;
  String _lastSearchQuery = '';
  StreamSubscription<void>? _dbChangeSubscription;
  int _sessionLoadSeq = 0;

  // 搜索相关
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late AnimationController _searchAnimationController;
  late Animation<double> _searchAnimation;

  @override
  void initState() {
    super.initState();
    _refreshController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _searchAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _searchAnimation = CurvedAnimation(
      parent: _searchAnimationController,
      curve: Curves.easeInOut,
    );
    _searchController.addListener(_onSearchChanged);
    _listenDatabaseChanges();
    _loadSessions();
    _scrollController = ScrollController()..addListener(_onScroll);
    _loadMyAvatar();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureConnected();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _refreshController.dispose();
    _searchAnimationController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _dbChangeSubscription?.cancel();
    super.dispose();
  }

  void _onSearchChanged() async {
    final query = _searchController.text.trim().toLowerCase();
    if (query == _lastSearchQuery) return;
    _lastSearchQuery = query;

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() {
        _filteredSessions = _filterSessionsByQuery(_sessions, query);
        logger.debug('ChatPage', '搜索结果: 找到 ${_filteredSessions.length} 个匹配的会话');
      });
    });
    await logger.debug('ChatPage', '搜索关键词: "$query"');
  }

  Future<void> _ensureConnected() async {
    final appState = context.read<AppState>();
    if (!appState.isConfigured) return;
    if (appState.databaseService.isConnected || appState.isLoading) return;
    if (_isAutoConnecting) return;

    setState(() {
      _isAutoConnecting = true;
      _hasAttemptedRefreshAfterConnect = false;
    });
    try {
      await appState.reconnectDatabase();
      if (mounted) {
        await _loadSessions();
        _hasAttemptedRefreshAfterConnect = true;
      }
    } catch (_) {
      // 失败交给 UI 提示
    } finally {
      if (mounted) {
        setState(() {
          _isAutoConnecting = false;
        });
        // 若仍未连接，再尝试一次刷新会话列表以防遗漏
        if (!_hasAttemptedRefreshAfterConnect &&
            appState.databaseService.isConnected) {
          _hasAttemptedRefreshAfterConnect = true;
          unawaited(_loadSessions());
        }
      }
    }
  }

  Future<void> _loadMyAvatar() async {
    try {
      final appState = context.read<AppState>();
      final myWxid = appState.databaseService.currentAccountWxid;
      if (myWxid == null || myWxid.isEmpty) return;

      // 使用全局缓存更新我的头像
      await appState.fetchAndCacheAvatars([myWxid]);

      if (!mounted) return;
      setState(() {
        _myAvatarUrl = appState.getAvatarUrl(myWxid);
      });
    } catch (_) {}
  }

  void _toggleSearch() async {
    await logger.debug('ChatPage', '切换搜索模式: ${!_isSearching}');

    setState(() {
      _isSearching = !_isSearching;
      if (_isSearching) {
        _searchAnimationController.forward();
        _searchFocusNode.requestFocus();
      } else {
        _searchAnimationController.reverse();
        _searchController.clear();
        _filteredSessions = _sessions;
        _searchFocusNode.unfocus();
      }
    });
  }

  bool _shouldAnimateAvatar(String? username, AppState appState) {
    if (username == null || username.isEmpty) return true;
    return !appState.isAvatarCached(username);
  }

  List<ChatSession> _filterSessionsByQuery(
    List<ChatSession> source,
    String query,
  ) {
    if (query.isEmpty) return source;
    final lower = query.toLowerCase();
    return source.where((session) {
      final displayName = session.displayName?.toLowerCase() ?? '';
      final username = session.username.toLowerCase();
      final summary = session.displaySummary.toLowerCase();
      return displayName.contains(lower) ||
          username.contains(lower) ||
          summary.contains(lower);
    }).toList();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || !_hasMoreMessages) {
      return;
    }

    final position = _scrollController.position;
    final distanceToTop = position.pixels;

    if (distanceToTop > _prefetchTriggerDistance) {
      _prefetchScheduled = false;
    }

    if (_isLoadingMoreMessages) {
      return;
    }

    if (distanceToTop <= _loadTriggerDistance) {
      _prefetchScheduled = false;
      _loadMoreMessages();
    } else if (distanceToTop <= _prefetchTriggerDistance &&
        position.userScrollDirection == ScrollDirection.reverse &&
        !_prefetchScheduled) {
      _prefetchScheduled = true;
      _loadMoreMessages();
    }
  }

  void _queueRealtimeRefresh() {
    if (_realtimeRefreshFuture != null) {
      _realtimeRefreshQueued = true;
      return;
    }
    _realtimeRefreshFuture = _refreshRealtimeData().whenComplete(() {
      _realtimeRefreshFuture = null;
      if (_realtimeRefreshQueued) {
        _realtimeRefreshQueued = false;
        _queueRealtimeRefresh();
      }
    });
  }

  void _listenDatabaseChanges() {
    _dbChangeSubscription?.cancel();
    final dbService = context.read<AppState>().databaseService;
    _dbChangeSubscription = dbService.databaseChangeStream.listen((_) {
      _queueRealtimeRefresh();
    });
  }

  Future<void> _refreshRealtimeData() async {
    if (_isRealtimeRefreshing || !mounted) return;
    _realtimeTick++;
    final appState = context.read<AppState>();
    if (appState.databaseService.mode != DatabaseMode.realtime ||
        !appState.databaseService.isConnected) {
      return;
    }

    _isRealtimeRefreshing = true;
    try {
      final refreshSessions = _realtimeTick % 3 == 0;
      if (refreshSessions) {
        await _refreshRealtimeSessions(appState);
      }
      await _refreshRealtimeMessages(appState);
    } finally {
      _isRealtimeRefreshing = false;
    }
  }

  bool _sessionsChanged(List<ChatSession> fresh) {
    if (fresh.length != _sessions.length) return true;
    final checkLength = fresh.length < 20 ? fresh.length : 20;
    for (int i = 0; i < checkLength; i++) {
      final a = fresh[i];
      final b = _sessions[i];
      if (a.username != b.username ||
          a.sortTimestamp != b.sortTimestamp ||
          a.lastTimestamp != b.lastTimestamp ||
          a.summary != b.summary) {
        return true;
      }
    }
    return false;
  }

  Future<void> _refreshRealtimeSessions(AppState appState) async {
    if (_isLoadingSessions) return;
    try {
      final sessions = await appState.databaseService.getSessions();
      final filteredSessions = sessions.where((session) {
        return ChatSession.shouldKeep(session.username);
      }).toList();

      if (!_sessionsChanged(filteredSessions)) return;

      if (!mounted) return;
      setState(() {
        _sessions = filteredSessions;
        final query = _searchController.text.trim().toLowerCase();
        _filteredSessions = _filterSessionsByQuery(_sessions, query);
      });

      final usernamesToFetch = filteredSessions
          .map((s) => s.username)
          .where((u) => !appState.isAvatarCached(u))
          .toList();
      if (usernamesToFetch.isNotEmpty) {
        await appState.fetchAndCacheAvatars(usernamesToFetch);
      }
    } catch (e, stackTrace) {
      await logger.debug('ChatPage', '实时刷新会话失败: $e $stackTrace');
    }
  }

  int _messageTimeKey(Message m) {
    if (m.sortSeq != 0) return m.sortSeq;
    return m.createTime;
  }

  String _buildMessageKey(Message m) {
    return '${m.localId}_${m.createTime}_${m.sortSeq}';
  }

  Future<void> _refreshRealtimeMessages(AppState appState) async {
    if (_selectedSession == null ||
        _isLoadingMessages ||
        _isLoadingMoreMessages) {
      return;
    }

    try {
      const fetchLimit = 30; // 拉取一个固定窗口，避免计数开销
      final latestBatch = await appState.databaseService.getMessages(
        _selectedSession!.username,
        limit: fetchLimit,
        offset: 0,
      );
      if (latestBatch.isEmpty) return;

      if (_messages.isEmpty) {
        // 尚未加载过，交给正常加载流程
        return;
      }

      final incoming = latestBatch.reversed.toList(); // oldest -> newest
      final List<Message> newOnes = [];
      final lastKey = _messageTimeKey(_messages.last);

      for (final msg in incoming) {
        final key = _messageTimeKey(msg);
        if (key <= lastKey) continue;
        final composite = _buildMessageKey(msg);
        if (_messageKeys.contains(composite)) continue;
        _messageKeys.add(composite);
        newOnes.add(msg);
      }

      if (newOnes.isEmpty || !mounted) return;
      setState(() {
        _messages.addAll(newOnes);
        _currentOffset = _messages.length;
      });

      // 若靠近底部，自动跟随新消息
      if (_scrollController.hasClients) {
        final distanceToBottom =
            _scrollController.position.maxScrollExtent -
            _scrollController.position.pixels;
        if (distanceToBottom < 80) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scrollController.hasClients) return;
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            );
          });
        }
      }

      if (_selectedSession!.isGroup && newOnes.isNotEmpty) {
        final newSenders = latestBatch
            .where(
              (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
            )
            .map((m) => m.senderUsername!)
            .where((username) => !_senderDisplayNames.containsKey(username))
            .toSet()
            .toList();

        if (newSenders.isNotEmpty) {
          final names = await appState.databaseService.getDisplayNames(
            newSenders,
          );
          if (mounted && _selectedSession != null) {
            setState(() {
              _senderDisplayNames.addAll(names);
            });
          }
          await appState.fetchAndCacheAvatars(newSenders);
        }
      }
    } catch (e, stackTrace) {
      await logger.debug('ChatPage', '实时刷新消息失败: $e $stackTrace');
    }
  }

  Future<void> _loadSessions() async {
    // 防止重复加载
    if (_isLoadingSessions) return;

    setState(() {
      _isLoadingSessions = true;
    });

    // 启动旋转动画
    _refreshController.repeat();

    try {
      final appState = context.read<AppState>();

      // 检查数据库是否已连接
      if (!appState.databaseService.isConnected) {
        if (mounted) {
          setState(() {
            _isLoadingSessions = false;
          });
          _refreshController.stop();
          _refreshController.reset();
        }
        return; // 数据库未连接，不显示错误，由UI显示提示
      }

      // 异步加载会话列表
      final sessions = await appState.databaseService.getSessions();

      // 在后台线程过滤会话
      final filteredSessions = sessions.where((session) {
        return ChatSession.shouldKeep(session.username);
      }).toList();
      if (mounted) {
        setState(() {
          _sessions = filteredSessions;
          _filteredSessions = filteredSessions; // 初始化过滤列表
          _isLoadingSessions = false;
        });
        _refreshController.stop();
        _refreshController.reset();
      }

      // 确保我的头像已加载（数据库连接后再尝试一次）
      if (_myAvatarUrl == null || _myAvatarUrl!.isEmpty) {
        await _loadMyAvatar();
      }

      // 异步加载头像（使用全局缓存）
      try {
        final appState = context.read<AppState>();
        final usernamesToFetch = filteredSessions
            .map((s) => s.username)
            .where((u) => !appState.isAvatarCached(u))
            .toList();
        if (usernamesToFetch.isNotEmpty) {
          await appState.fetchAndCacheAvatars(usernamesToFetch);
        }
      } catch (_) {}
    } catch (e, stackTrace) {
      await logger.error('ChatPage', '加载会话列表失败', e, stackTrace);
      if (mounted) {
        setState(() {
          _isLoadingSessions = false;
        });
        _refreshController.stop();
        _refreshController.reset();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载会话列表失败: $e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _loadMessages(ChatSession session) async {
    final loadId = ++_sessionLoadSeq;
    await logger.info(
      'ChatPage',
      '开始加载会话消息: ${session.username} (${session.displayName ?? "无显示名"})',
    );

    // 立即切换选中状态，不等待加载，避免卡顿
    setState(() {
      _selectedSession = session;
      _isLoadingMessages = true;
      _currentOffset = 0;
      _hasMoreMessages = true;
      _senderDisplayNames = {}; // 清空姓名缓存
      _messages = []; // 清空旧消息
      _lastInitialLoadTime = null; // 重置初次加载时间
      _prefetchScheduled = false;
      _resetScrollController();
    });

    // 异步加载消息 - 初次只加载少量消息以提升性能
    try {
      final appState = context.read<AppState>();
      // 若我的头像尚未就绪，尝试补载
      if (_myAvatarUrl == null || _myAvatarUrl!.isEmpty) {
        _loadMyAvatar(); // 不等待，并行加载
      }
      await logger.info(
        'ChatPage',
        '查询消息，limit=$_initialMessageBatch, offset=0',
      );
      final messages = await appState.databaseService.getMessages(
        session.username,
        limit: _initialMessageBatch,
        offset: 0,
      );

      if (!mounted) {
        return;
      }

      // 如果用户已切换会话，丢弃结果
      if (_sessionLoadSeq != loadId ||
          _selectedSession?.username != session.username) {
        await logger.info(
          'ChatPage',
          '会话已切换，丢弃旧的消息结果: ${session.username}',
        );
        return;
      }

      await logger.info('ChatPage', '获取到 ${messages.length} 条消息');

      // 1. 先渲染消息，让用户立刻看到内容（渐进式渲染）
      setState(() {
        _messages = messages.reversed.toList(); // 反转顺序，最新消息在下方
        _messageKeys
          ..clear()
          ..addAll(_messages.map(_buildMessageKey));
        _isLoadingMessages = false;
        _currentOffset = messages.length;
        _hasMoreMessages = messages.length >= _initialMessageBatch;
      });

      // 自动滚动到底部（最新消息）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _scrollController.hasClients &&
            _selectedSession?.username == session.username) {
          try {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          } catch (e) {
            // 忽略滚动错误
          }
        }
      });

      // 2. 如果是群聊，后台加载发送者显示名和头像
      if (session.isGroup && messages.isNotEmpty) {
        // 不await，让它在后台运行
        _loadGroupMemberInfo(session, messages);
      }

      // 如果消息数量接近初始加载限制，延迟自动加载更多消息，提升用户体验
      if (messages.length >= _initialMessageBatch - 10) {
        // 记录初次加载时间，用于避免与用户滚动触发的加载冲突
        _lastInitialLoadTime = DateTime.now();
        Future.delayed(const Duration(milliseconds: 300), () {
          // 检查是否是初次加载后不久（避免与用户滚动触发的加载冲突）
          if (mounted &&
              _selectedSession?.username == session.username &&
              !_isLoadingMoreMessages &&
              _lastInitialLoadTime != null &&
              DateTime.now().difference(_lastInitialLoadTime!).inMilliseconds <
                  1000) {
            _loadMoreMessages();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        if (_sessionLoadSeq == loadId) {
          setState(() {
            _isLoadingMessages = false;
          });
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载消息失败: $e')));
      }
    }
  }

  void _resetScrollController() {
    final oldController = _scrollController;
    _scrollController = ScrollController()..addListener(_onScroll);
    oldController.removeListener(_onScroll);
    // 等待新列表构建完毕后再安全释放旧控制器，避免仍有附着的滚动位置导致报错
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !oldController.hasClients) {
        oldController.dispose();
      } else {
        // 再排队一次，确保彻底分离后释放
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!oldController.hasClients) {
            oldController.dispose();
          }
        });
      }
    });
  }

  // 新增：专门加载群成员信息的方法
  Future<void> _loadGroupMemberInfo(
    ChatSession session,
    List<Message> messages,
  ) async {
    try {
      final appState = context.read<AppState>();
      await logger.info('ChatPage', '这是群聊，开始后台查询发送者显示名');
      final senderUsernames = messages
          .where(
            (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
          )
          .map((m) => m.senderUsername!)
          .toSet()
          .toList();

      if (senderUsernames.isNotEmpty) {
        await logger.info('ChatPage', '查询 ${senderUsernames.length} 个发送者的显示名');
        final names = await appState.databaseService.getDisplayNames(
          senderUsernames,
        );

        if (!mounted || _selectedSession?.username != session.username) return;

        setState(() {
          _senderDisplayNames.addAll(names);
        });

        // 同时查询头像（使用全局缓存）
        try {
          await appState.fetchAndCacheAvatars(senderUsernames);
        } catch (_) {}

        await logger.info('ChatPage', '获取到 ${names.length} 个显示名');
      }
    } catch (e) {
      logger.error('ChatPage', '加载群成员信息失败', e);
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMoreMessages ||
        !_hasMoreMessages ||
        _selectedSession == null) {
      return;
    }

    // 检查 ScrollController 是否已附加
    if (!_scrollController.hasClients) {
      return;
    }

    setState(() {
      _isLoadingMoreMessages = true;
    });

    try {
      final appState = context.read<AppState>();
      final oldPixels = _scrollController.position.pixels;
      final oldMaxExtent = _scrollController.position.maxScrollExtent;
      final currentSessionUsername = _selectedSession?.username; // 保存当前会话

      final moreMessages = await appState.databaseService.getMessages(
        _selectedSession!.username,
        limit: _loadMoreBatch,
        offset: _currentOffset,
      );

      // 如果是群聊，批量查询新加载消息的发送者姓名
      if (_selectedSession!.isGroup && moreMessages.isNotEmpty) {
        final newSenderUsernames = moreMessages
            .where(
              (m) => m.senderUsername != null && m.senderUsername!.isNotEmpty,
            )
            .map((m) => m.senderUsername!)
            .toSet()
            .where((username) => !_senderDisplayNames.containsKey(username))
            .toList();

        if (newSenderUsernames.isNotEmpty) {
          final newNames = await appState.databaseService.getDisplayNames(
            newSenderUsernames,
          );
          _senderDisplayNames.addAll(newNames);
        }
      }

      if (mounted && _selectedSession?.username == currentSessionUsername) {
        setState(() {
          final prepend = moreMessages.reversed.toList();
          _messageKeys.addAll(prepend.map(_buildMessageKey));
          _messages = [...prepend, ..._messages];
          _isLoadingMoreMessages = false;
          _currentOffset += moreMessages.length;
          _hasMoreMessages = moreMessages.length >= _loadMoreBatch;
        });

        // 维持可视位置不跳动
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _scrollController.hasClients &&
              _selectedSession?.username == currentSessionUsername) {
            try {
              final newMaxExtent = _scrollController.position.maxScrollExtent;
              final delta = newMaxExtent - oldMaxExtent;
              final target = oldPixels + delta;
              if (target >= 0 &&
                  target <= _scrollController.position.maxScrollExtent) {
                _scrollController.jumpTo(target);
              }
            } catch (e) {
              // 忽略滚动错误
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMoreMessages = false;
        });
      }
    } finally {
      _prefetchScheduled = false;
    }
  }

  /// 判断消息是否为自己发送
  bool _isMessageFromMe(Message message) {
    if (message.isSystemLike) {
      return false;
    }
    if (message.isSend != null) {
      return message.isSend == 1;
    }
    // Fallback判断
    final myWxid =
        context.read<AppState>().databaseService.currentAccountWxid ?? '';
    return message.source.isEmpty || message.source == myWxid;
  }

  /// 获取会话显示名称（如果是自己的账号显示"我"）
  String _getSessionDisplayName(ChatSession session) {
    final myWxid =
        context.read<AppState>().databaseService.currentAccountWxid ?? '';

    // 如果会话用户名是当前账号，显示"我"
    if (session.username == myWxid) {
      return '我';
    }

    return session.displayName ?? session.username;
  }

  /// 获取发送者显示名称（如果是自己显示"我"）
  String? _getSenderDisplayName(Message message) {
    if (_selectedSession == null || !_selectedSession!.isGroup) {
      return null;
    }

    // 如果是自己发的消息，不显示名称
    if (_isMessageFromMe(message)) {
      return null;
    }

    final myWxid =
        context.read<AppState>().databaseService.currentAccountWxid ?? '';

    // 获取发送者username
    if (message.senderUsername != null && message.senderUsername!.isNotEmpty) {
      // 如果发送者是当前账号（虽然理论上不会走到这里）
      if (message.senderUsername == myWxid) {
        return '我';
      }

      // 从缓存中获取显示名称
      String? displayName = _senderDisplayNames[message.senderUsername];

      // 如果没查到，显示默认提示而不是wxid
      if (displayName == null || displayName.isEmpty) {
        return '群成员';
      }

      return displayName;
    }

    return '群成员';
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final hasError = appState.errorMessage != null;
    final isConnecting = appState.isLoading ||
        _isAutoConnecting ||
        (!appState.databaseService.isConnected && !hasError);
    final showErrorOverlay = !appState.isLoading &&
        !appState.databaseService.isConnected &&
        hasError;
    if (!isConnecting &&
        !_isLoadingSessions &&
        _sessions.isEmpty &&
        !_autoLoadScheduled &&
        appState.databaseService.isConnected) {
      _autoLoadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _autoLoadScheduled = false;
        await _loadSessions();
      });
    }
    return Stack(
      children: [
        Row(
          children: [
        // 左侧会话列表
        Container(
          width: 300,
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(2, 0),
              ),
            ],
          ),
          child: Column(
            children: [
              // 会话列表头部
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      '会话列表',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(_isSearching ? Icons.close : Icons.search),
                      onPressed: _toggleSearch,
                      tooltip: _isSearching ? '关闭搜索' : '搜索',
                    ),
                    IconButton(
                      icon: RotationTransition(
                        turns: _refreshController,
                        child: const Icon(Icons.refresh),
                      ),
                      onPressed: _loadSessions,
                      tooltip: '刷新',
                    ),
                  ],
                ),
              ),
              // 搜索框（带动画）
              SizeTransition(
                sizeFactor: _searchAnimation,
                axisAlignment: -1.0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.outline.withValues(alpha: 0.1),
                      ),
                    ),
                  ),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    decoration: InputDecoration(
                      hintText: '搜索会话或消息内容...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      isDense: true,
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
              // 会话列表
              Expanded(
                child: Consumer<AppState>(
                  builder: (context, appState, child) {
                    if (!appState.databaseService.isConnected) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.storage_rounded,
                              size: 64,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '数据库未连接',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.7),
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '请先在「数据管理」页面\n解密数据库文件',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.5),
                                  ),
                            ),
                          ],
                        ),
                      );
                    }

                    Widget sessionChild;
                    if (_isLoadingSessions) {
                      sessionChild = ShimmerLoading(
                        key: const ValueKey('session-loading'),
                        isLoading: true,
                        child: ListView.builder(
                          itemCount: 6,
                          physics: const NeverScrollableScrollPhysics(),
                          itemBuilder: (context, index) =>
                              const ListItemShimmer(),
                        ),
                      );
                    } else if (_filteredSessions.isEmpty) {
                      sessionChild = Center(
                        key: const ValueKey('session-empty'),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _isSearching
                                  ? Icons.search_off
                                  : Icons.chat_bubble_outline,
                              size: 64,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _isSearching ? '未找到匹配的会话' : '暂无会话',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.5),
                                  ),
                            ),
                          ],
                        ),
                      );
                    } else {
                      sessionChild = ListView.builder(
                        key: const ValueKey('session-list'),
                        cacheExtent: 600,
                        addAutomaticKeepAlives: false,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: _filteredSessions.length,
                        itemBuilder: (context, index) {
                          final session = _filteredSessions[index];
                          return ChatSessionItem(
                            session: session,
                            isSelected:
                                _selectedSession?.username == session.username,
                            onTap: () => _loadMessages(session),
                            avatarUrl: appState.getAvatarUrl(
                              session.username,
                            ),
                            enableAvatarFade: _shouldAnimateAvatar(
                              session.username,
                              appState,
                            ),
                          );
                        },
                      );
                    }

                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) {
                        final slide = Tween<Offset>(
                          begin: const Offset(0, 0.02),
                          end: Offset.zero,
                        ).animate(animation);
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: slide,
                            child: child,
                          ),
                        );
                      },
                      child: sessionChild,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // 右侧消息列表
        Expanded(
          child: _selectedSession == null
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    // 消息列表头部
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          _buildSelectedSessionAvatar(context, appState),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getSessionDisplayName(_selectedSession!),
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  _selectedSession!.typeDescription,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 消息列表
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: _isLoadingMessages ? 1 : 0,
                              child: const IgnorePointer(
                                child: MessageLoadingShimmer(
                                  key: ValueKey('msg-loading'),
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 220),
                              opacity: _isLoadingMessages ? 0 : 1,
                              child: _messages.isEmpty
                                  ? Center(
                                      child: Text(
                                        '暂无消息',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.5),
                                            ),
                                      ),
                                    )
                                  : ListView.builder(
                                      controller: _scrollController,
                                      padding: const EdgeInsets.all(16),
                                      cacheExtent: 800,
                                      addAutomaticKeepAlives: false,
                                      itemCount: _messages.length +
                                          (_isLoadingMoreMessages ? 1 : 0),
                                      itemBuilder: (context, index) {
                                        if (_isLoadingMoreMessages &&
                                            index == 0) {
                                          return const Padding(
                                            padding:
                                                EdgeInsets.only(bottom: 12),
                                            child: MessageLoadingShimmer(),
                                          );
                                        }

                                        final offset =
                                            _isLoadingMoreMessages ? 1 : 0;
                                        final message =
                                            _messages[index - offset];

                                        final senderName =
                                            _getSenderDisplayName(message);

                                        bool shouldShowTime = false;
                                        if (index - offset == 0) {
                                          shouldShowTime = true;
                                        } else {
                                          final previousMessage =
                                              _messages[index - offset - 1];
                                          final timeDiff =
                                              message.createTime -
                                                  previousMessage.createTime;
                                          shouldShowTime = timeDiff > 600;
                                        }

                                        final avatarUrl =
                                            _selectedSession?.isGroup == true
                                                ? (message.senderUsername != null
                                                    ? appState.getAvatarUrl(
                                                        message.senderUsername!,
                                                      )
                                                    : null)
                                                : appState.getAvatarUrl(
                                                    _selectedSession!.username,
                                                  );

                                        final avatarOwner = _isMessageFromMe(
                                          message,
                                        )
                                            ? appState.databaseService
                                                    .currentAccountWxid ??
                                                ''
                                            : (message.senderUsername ??
                                                _selectedSession?.username ??
                                                '');
                                        final animateAvatar =
                                            _shouldAnimateAvatar(
                                          avatarOwner,
                                          appState,
                                        );

                                        return MessageBubble(
                                          key: ValueKey(
                                              'msg-${message.localId}-${message.createTime}'),
                                          message: message,
                                          isFromMe: _isMessageFromMe(message),
                                          senderDisplayName: senderName,
                                          sessionUsername:
                                              _selectedSession?.username ?? '',
                                          shouldShowTime: shouldShowTime,
                                          avatarUrl: _isMessageFromMe(message)
                                              ? _myAvatarUrl
                                              : avatarUrl,
                                          enableAvatarFade: animateAvatar,
                                        );
                                      },
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: showErrorOverlay
                ? Container(
                    color: Colors.white.withValues(alpha: 0.9),
                    child: Center(
                      child: _buildErrorOverlay(
                        context,
                        appState,
                        appState.errorMessage ?? '未能连接数据库',
                      ),
                    ),
                  )
                : isConnecting
                ? Container(
                    color: Colors.white.withValues(alpha: 0.9),
                    child: Center(
                      child: _buildFancyLoader(context),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _buildFancyLoader(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 72,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(3, (index) {
                  final delay = index * 0.15;
                  final t = (value - delay).clamp(0.0, 1.0);
                  final height = 10 + 26 * Curves.easeInOut.transform(t);
                  final opacity = 0.2 + 0.6 * t;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOut,
                    width: 10,
                    height: height,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: opacity),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '正在连接数据库...',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.8),
                  ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildErrorOverlay(
    BuildContext context,
    AppState appState,
    String message,
  ) {
    final theme = Theme.of(context);
    final lower = message.toLowerCase();
    bool isMissingDb = lower.contains('未找到') ||
        lower.contains('不存在') ||
        lower.contains('no such file') ||
        lower.contains('not found');

    final resolvedPath = appState.resolvedSessionDbPath;
    if (resolvedPath != null) {
      try {
        if (!File(resolvedPath).existsSync()) {
          isMissingDb = true;
        }
      } catch (_) {}
    }

    final hint = isMissingDb
        ? '未找到对应账号的数据库文件，请先在「数据管理」页面解密当前选择的 wxid。'
        : '请检查数据库解密状态和密钥配置，或前往数据管理页面查看解密状态。';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.12),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.error_outline,
              size: 36,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            isMissingDb ? '未找到数据库文件' : '无法连接数据库',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.error,
              letterSpacing: 0.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 6),
          if (isMissingDb && resolvedPath != null)
            Text(
              '路径: $resolvedPath',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            )
          else
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: () =>
                    context.read<AppState>().setCurrentPage('data_management'),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                ),
                child: const Text('前往数据管理'),
              ),
              OutlinedButton(
                onPressed: () =>
                    context.read<AppState>().setCurrentPage('settings'),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  side: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.4),
                  ),
                ),
                child: const Text('重新配置'),
              ),
            ],
          ),
        ],
      ),
    );
  }


  Widget _buildSelectedSessionAvatar(BuildContext context, AppState appState) {
    final avatarUrl = _selectedSession != null
        ? appState.getAvatarUrl(_selectedSession!.username)
        : null;
    final animateAvatar = _selectedSession != null
        ? _shouldAnimateAvatar(_selectedSession!.username, appState)
        : true;

    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: avatarUrl,
        fadeInDuration: animateAvatar
            ? const Duration(milliseconds: 200)
            : Duration.zero,
        fadeOutDuration: animateAvatar
            ? const Duration(milliseconds: 200)
            : Duration.zero,
        imageBuilder: (context, imageProvider) => CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          backgroundImage: imageProvider,
        ),
        placeholder: (context, url) => CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(
            StringUtils.getFirstChar(
              _selectedSession!.displayName ?? _selectedSession!.username,
            ),
            style: const TextStyle(color: Colors.white),
          ),
        ),
        errorWidget: (context, url, error) => CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(
            StringUtils.getFirstChar(
              _selectedSession!.displayName ?? _selectedSession!.username,
            ),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    } else {
      return CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: Text(
          StringUtils.getFirstChar(
            _selectedSession!.displayName ?? _selectedSession!.username,
          ),
          style: const TextStyle(color: Colors.white),
        ),
      );
    }
  }
}
