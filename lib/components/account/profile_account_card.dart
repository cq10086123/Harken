import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/account_entry.dart';
import '../../app/services/feiniu/account_store.dart';

/// 「我的」页专属账号展示卡片。
///
/// 与侧边栏共用的紧凑条状 [AccountHeaderCard] 不同，这里用更宽松的
/// 横向布局：左侧头像、右侧展示名 + 服务器/FNID + 登录状态徽标，
/// 点击进入账号切换页。无当前账号时渲染为空。
class ProfileAccountCard extends StatelessWidget {
  const ProfileAccountCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: AccountStore.instance.currentAccountId,
      builder: (context, accountId, _) {
        final account = AccountStore.instance.currentAccount;
        // 未登录：显示引导卡片，点击进入账号管理（添加新账号 = 登录）。
        if (account == null) return const _ProfileLoginHintCard();
        return _ProfileAccountCardInner(account: account);
      },
    );
  }
}

/// 未登录时的引导卡片：本地音源无需账号，登录飞牛可选。
class _ProfileLoginHintCard extends StatelessWidget {
  const _ProfileLoginHintCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.accounts),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.16),
                ),
                child: Icon(Icons.person_outline, color: scheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('未登录飞牛账号',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '本地音源无需登录；点此登录后可播放在线曲库',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileAccountCardInner extends StatelessWidget {
  final AccountEntry account;

  const _ProfileAccountCardInner({required this.account});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.accounts),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          decoration: BoxDecoration(
            // 柔和的渐变底色：主题色淡出，与首页大卡片的视觉语言一致
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primary.withValues(alpha: 0.14),
                scheme.primary.withValues(alpha: 0.04),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              // 左侧头像
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.16),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.22),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.24),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  account.username.isNotEmpty
                      ? account.username.characters.first
                      : '?',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              // 右侧信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      account.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${account.username} · ${account.serverLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              // 右侧箭头
              Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
