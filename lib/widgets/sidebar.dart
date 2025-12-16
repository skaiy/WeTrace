import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../providers/app_state.dart';

/// 侧边栏组件（可折叠）
class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> with SingleTickerProviderStateMixin {
  bool _isCollapsed = false;
  late AnimationController _animationController;
  late Animation<double> _widthAnimation;
  bool _showContent = true; // 控制内容显示
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _widthAnimation = Tween<double>(begin: 220.0, end: 72.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // 监听动画进度，在适当时机切换内容显示
    _animationController.addListener(() {
      if (_animationController.value > 0.3 && _showContent && _isCollapsed) {
        // 收起时，动画进行到30%就隐藏文字
        setState(() {
          _showContent = false;
        });
      } else if (_animationController.value < 0.7 &&
          !_showContent &&
          !_isCollapsed) {
        // 展开时，动画进行到70%（从1到0.7）才显示文字
        setState(() {
          _showContent = true;
        });
      }
    });
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = 'v${packageInfo.version}';
      });
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _toggleSidebar() {
    setState(() {
      _isCollapsed = !_isCollapsed;
      if (_isCollapsed) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _widthAnimation,
      builder: (context, child) {
        return Container(
          width: _widthAnimation.value,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              right: BorderSide(
                color: Theme.of(context).dividerTheme.color!,
                width: 1,
              ),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 32),

              // 标题（顶部，仅展开时显示）
              if (_showContent) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'WeTrace',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ] else ...[
                const SizedBox(height: 12),
                // 收起时显示首字母
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'E',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // 导航按钮
              Expanded(
                child: SingleChildScrollView(
                  child: Consumer<AppState>(
                    builder: (context, appState, child) {
                      return Column(
                        children: [
                          _SidebarButton(
                            icon: Icons.chat_bubble_outline,
                            label: '聊天记录',
                            showLabel: _showContent,
                            isSelected: appState.currentPage == 'chat',
                            onTap: () => appState.setCurrentPage('chat'),
                          ),
                          _SidebarButton(
                            icon: Icons.analytics_outlined,
                            label: '数据分析',
                            showLabel: _showContent,
                            isSelected: appState.currentPage == 'analytics',
                            onTap: () => appState.setCurrentPage('analytics'),
                          ),
                          _SidebarButton(
                            icon: Icons.groups_outlined,
                            label: '群聊分析',
                            showLabel: _showContent,
                            isSelected:
                                appState.currentPage == 'group_chat_analysis',
                            onTap: () =>
                                appState.setCurrentPage('group_chat_analysis'),
                          ),
                          _SidebarButton(
                            icon: Icons.file_download_outlined,
                            label: '导出记录',
                            showLabel: _showContent,
                            isSelected: appState.currentPage == 'export',
                            onTap: () => appState.setCurrentPage('export'),
                          ),
                          _SidebarButton(
                            icon: Icons.folder_outlined,
                            label: '数据管理',
                            showLabel: _showContent,
                            isSelected:
                                appState.currentPage == 'data_management',
                            onTap: () =>
                                appState.setCurrentPage('data_management'),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),

              // 设置按钮（固定在底部）
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Consumer<AppState>(
                  builder: (context, appState, child) {
                    return _SidebarButton(
                      icon: Icons.settings_outlined,
                      label: '设置',
                      showLabel: _showContent,
                      isSelected: appState.currentPage == 'settings',
                      onTap: () => appState.setCurrentPage('settings'),
                    );
                  },
                ),
              ),

              // 版本信息和折叠按钮
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: _showContent ? 24 : 12,
                  vertical: 24,
                ),
                child: Row(
                  mainAxisAlignment: _showContent
                      ? MainAxisAlignment.spaceBetween
                      : MainAxisAlignment.center,
                  children: [
                    if (_showContent)
                      Expanded(
                        child: Text(
                          _version,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.4),
                              ),
                        ),
                      ),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _toggleSidebar,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).dividerTheme.color!,
                            ),
                          ),
                          child: Icon(
                            _isCollapsed
                                ? Icons.chevron_right
                                : Icons.chevron_left,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 侧边栏按钮
class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool showLabel;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarButton({
    required this.icon,
    required this.label,
    required this.showLabel,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: showLabel ? 16 : 12,
        vertical: 4,
      ),
      child: Material(
        color: isSelected
            ? colorScheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: colorScheme.primary.withValues(alpha: 0.04),
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: showLabel ? 16 : 0,
              vertical: 12,
            ),
            child: Row(
              mainAxisAlignment: showLabel
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                if (showLabel) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurface.withValues(alpha: 0.8),
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
