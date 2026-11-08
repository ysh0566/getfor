import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auto_lock.dart';
import 'core_ffi.dart';
import 'lan_sync.dart';
import 'password_tools.dart';
import 'totp.dart';

const _background = Color(0xFF051424);
const _sidebar = Color(0xFF061526);
const _surface = Color(0x99122131);
const _surfaceHigh = Color(0xFF1C2B3C);
const _surfaceHighest = Color(0xFF273647);
const _outline = Color(0x3345464D);
const _text = Color(0xFFD4E4FA);
const _muted = Color(0xFFC6C6CD);
const _success = Color(0xFF4EDEA3);
const _warning = Color(0xFFFFC857);

enum VaultSection { dashboard, vault, security, sharing, settings }

enum VaultCategoryFilter { all, logins, totp, passkeys }

class VaultShell extends StatefulWidget {
  const VaultShell({
    required this.records,
    required this.passwordAudit,
    required this.loadItem,
    required this.onAdd,
    required this.onGeneratePassword,
    required this.onEdit,
    required this.onDelete,
    required this.onImport,
    required this.onEnableAutoFill,
    required this.onChangeMasterPassword,
    required this.onEnableQuickUnlock,
    required this.quickUnlockAvailable,
    required this.autoLockDelay,
    required this.onAutoLockDelayChanged,
    required this.lanPeers,
    required this.pairingAllowed,
    required this.onPairingAllowedChanged,
    required this.onPairDevice,
    required this.onSyncDevice,
    required this.onRevokeDevice,
    required this.onLock,
    required this.busy,
    super.key,
  });

  final List<VaultItemSummary> records;
  final PasswordAudit passwordAudit;
  final VaultItem Function(String id) loadItem;
  final VoidCallback onAdd;
  final VoidCallback onGeneratePassword;
  final ValueChanged<VaultItemSummary> onEdit;
  final ValueChanged<VaultItemSummary> onDelete;
  final VoidCallback onImport;
  final VoidCallback onEnableAutoFill;
  final VoidCallback onChangeMasterPassword;
  final VoidCallback onEnableQuickUnlock;
  final bool quickUnlockAvailable;
  final AutoLockDelay autoLockDelay;
  final ValueChanged<AutoLockDelay> onAutoLockDelayChanged;
  final List<LanPeer> lanPeers;
  final bool pairingAllowed;
  final ValueChanged<bool> onPairingAllowedChanged;
  final ValueChanged<LanPeer> onPairDevice;
  final ValueChanged<LanPeer> onSyncDevice;
  final ValueChanged<LanPeer> onRevokeDevice;
  final VoidCallback onLock;
  final bool busy;

  @override
  State<VaultShell> createState() => _VaultShellState();
}

class _VaultShellState extends State<VaultShell> {
  VaultSection _section = VaultSection.vault;
  VaultCategoryFilter _categoryFilter = VaultCategoryFilter.all;
  String _query = '';
  VaultItem? _selected;
  bool _showPassword = false;
  Timer? _clipboardTimer;
  Timer? _totpTimer;

  @override
  void initState() {
    super.initState();
    _totpTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _selected?.hasTotp == true) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant VaultShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected != null &&
        !widget.records.any((record) => record.id == _selected!.id)) {
      _selected = null;
    } else if (_selected != null) {
      _selected = widget.loadItem(_selected!.id);
    }
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    _totpTimer?.cancel();
    super.dispose();
  }

  void _select(VaultItemSummary summary) {
    try {
      setState(() {
        _selected = widget.loadItem(summary.id);
        _showPassword = false;
      });
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _copy(String value, String label) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    _message('$label已复制，30 秒后自动清除');
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Tablets keep list/detail panes; only wide windows have room for categories too.
        final mobile = constraints.maxWidth < 700;
        final compact = constraints.maxWidth < 1200;
        return Scaffold(
          backgroundColor: _background,
          body: SafeArea(
            child: Stack(
              children: [
                mobile
                    ? _buildSection(compact, mobile)
                    : Row(
                        children: [
                          _Sidebar(
                            compact: compact,
                            selected: _section,
                            onSelected: (section) =>
                                setState(() => _section = section),
                            onLock: widget.onLock,
                          ),
                          Expanded(child: _buildSection(compact, mobile)),
                        ],
                      ),
                if (widget.busy)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x66010F1F),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
          ),
          bottomNavigationBar: mobile
              ? NavigationBar(
                  selectedIndex: VaultSection.values.indexOf(_section),
                  labelBehavior:
                      NavigationDestinationLabelBehavior.onlyShowSelected,
                  onDestinationSelected: (index) =>
                      setState(() => _section = VaultSection.values[index]),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.dashboard_outlined),
                      label: '仪表盘',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.lock_outline),
                      label: '保险库',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.security_outlined),
                      label: '安全',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.sync_outlined),
                      label: '同步',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      label: '设置',
                    ),
                  ],
                )
              : null,
        );
      },
    );
  }

  Widget _buildSection(bool compact, bool mobile) => switch (_section) {
    VaultSection.dashboard => _DashboardPage(
      mobile: mobile,
      recordCount: widget.records.length,
      passwordAudit: widget.passwordAudit,
      onAdd: widget.onAdd,
      onGeneratePassword: widget.onGeneratePassword,
      onOpenVault: () => setState(() => _section = VaultSection.vault),
      onLock: widget.onLock,
    ),
    VaultSection.vault => _VaultPage(
      records: widget.records,
      selected: _selected,
      query: _query,
      categoryFilter: _categoryFilter,
      compact: compact,
      mobile: mobile,
      showPassword: _showPassword,
      onQueryChanged: (value) => setState(() => _query = value),
      onCategoryChanged: (cat) => setState(() => _categoryFilter = cat),
      onSelect: _select,
      onBack: () => setState(() => _selected = null),
      onAdd: widget.onAdd,
      onEdit: widget.onEdit,
      onDelete: widget.onDelete,
      onCopyPassword: () => _copy(_selected?.password ?? '', '密码'),
      onCopyTotp: () {
        final item = _selected;
        if (item == null || !item.hasTotp) return;
        _copy(
          generateTotp(
            item.totpSecret,
            period: item.totpPeriod,
            digits: item.totpDigits,
            algorithm: item.totpAlgorithm,
          ),
          '验证码',
        );
      },
      onCopyUsername: () => _copy(_selected?.username ?? '', '用户名'),
      onCopyWebsite: () => _copy(_selected?.website ?? '', '网址'),
      onTogglePassword: () => setState(() => _showPassword = !_showPassword),
      onLock: widget.onLock,
    ),
    VaultSection.security => _SecurityPage(
      audit: widget.passwordAudit,
      mobile: mobile,
      onLock: widget.onLock,
    ),
    VaultSection.sharing => _SharingPage(
      mobile: mobile,
      peers: widget.lanPeers,
      onPair: widget.onPairDevice,
      onSync: widget.onSyncDevice,
      onRevoke: widget.onRevokeDevice,
      onLock: widget.onLock,
    ),
    VaultSection.settings => _SettingsPage(
      mobile: mobile,
      onImport: widget.onImport,
      onEnableAutoFill: widget.onEnableAutoFill,
      onChangeMasterPassword: widget.onChangeMasterPassword,
      onEnableQuickUnlock: widget.onEnableQuickUnlock,
      quickUnlockAvailable: widget.quickUnlockAvailable,
      autoLockDelay: widget.autoLockDelay,
      onAutoLockDelayChanged: widget.onAutoLockDelayChanged,
      pairingAllowed: widget.pairingAllowed,
      onPairingAllowedChanged: widget.onPairingAllowedChanged,
      onLock: widget.onLock,
    ),
  };
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.compact,
    required this.selected,
    required this.onSelected,
    required this.onLock,
  });

  final bool compact;
  final VaultSection selected;
  final ValueChanged<VaultSection> onSelected;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final items = <(VaultSection, IconData, String)>[
      (VaultSection.dashboard, Icons.dashboard_outlined, '仪表盘'),
      (VaultSection.vault, Icons.lock_outline, '保险库'),
      (VaultSection.security, Icons.security_outlined, '安全中心'),
      (VaultSection.sharing, Icons.share_outlined, '共享'),
      (VaultSection.settings, Icons.settings_outlined, '设置'),
    ];
    return Container(
      width: compact ? 76 : 224,
      decoration: const BoxDecoration(
        color: _sidebar,
        border: Border(right: BorderSide(color: _outline)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 18 : 22, 24, 18, 28),
              child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  const Icon(Icons.shield_outlined, color: _text, size: 25),
                  if (!compact) ...[
                    const SizedBox(width: 10),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Getfor',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '本地保险库',
                          style: TextStyle(fontSize: 11, color: _success),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            for (final item in items)
              _NavButton(
                compact: compact,
                icon: item.$2,
                label: item.$3,
                selected: selected == item.$1,
                onTap: () => onSelected(item.$1),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: compact
                  ? IconButton.outlined(
                      onPressed: onLock,
                      icon: const Icon(Icons.lock_outline, size: 17),
                      tooltip: '锁定保险库',
                    )
                  : SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: onLock,
                        icon: const Icon(Icons.lock_outline, size: 17),
                        label: const Text(
                          '锁定保险库',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.compact,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final bool compact;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: selected ? _surfaceHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 15 : 14,
              vertical: 12,
            ),
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(icon, size: 19, color: selected ? _text : _muted),
                if (!compact) ...[
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: TextStyle(color: selected ? _text : _muted),
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

class _VaultPage extends StatelessWidget {
  const _VaultPage({
    required this.records,
    required this.selected,
    required this.query,
    required this.categoryFilter,
    required this.compact,
    required this.mobile,
    required this.showPassword,
    required this.onQueryChanged,
    required this.onCategoryChanged,
    required this.onSelect,
    required this.onBack,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    required this.onCopyPassword,
    required this.onCopyTotp,
    required this.onCopyUsername,
    required this.onCopyWebsite,
    required this.onTogglePassword,
    required this.onLock,
  });

  final List<VaultItemSummary> records;
  final VaultItem? selected;
  final String query;
  final VaultCategoryFilter categoryFilter;
  final bool compact;
  final bool mobile;
  final bool showPassword;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<VaultCategoryFilter> onCategoryChanged;
  final ValueChanged<VaultItemSummary> onSelect;
  final VoidCallback onBack;
  final VoidCallback onAdd;
  final ValueChanged<VaultItemSummary> onEdit;
  final ValueChanged<VaultItemSummary> onDelete;
  final VoidCallback onCopyPassword;
  final VoidCallback onCopyTotp;
  final VoidCallback onCopyUsername;
  final VoidCallback onCopyWebsite;
  final VoidCallback onTogglePassword;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final filtered = records
        .where((record) {
          switch (categoryFilter) {
            case VaultCategoryFilter.logins:
              if (!record.hasPassword) return false;
            case VaultCategoryFilter.totp:
              if (!record.hasTotp) return false;
            case VaultCategoryFilter.passkeys:
              if (!record.hasPasskey) return false;
            case VaultCategoryFilter.all:
              break;
          }
          if (normalized.isEmpty) return true;
          return '${record.title} ${record.username} ${record.website}'
              .toLowerCase()
              .contains(normalized);
        })
        .toList(growable: false);
    final details = selected == null
        ? const _EmptyState(
            icon: Icons.touch_app_outlined,
            title: '选择一个项目',
            detail: '在这里查看登录信息和执行安全操作。',
          )
        : _RecordDetails(
            record: selected!,
            showPassword: showPassword,
            onTogglePassword: onTogglePassword,
            onCopyPassword: onCopyPassword,
            onCopyTotp: onCopyTotp,
            onCopyUsername: onCopyUsername,
            onCopyWebsite: onCopyWebsite,
            onEdit: () {
              final summary = records.firstWhere(
                (item) => item.id == selected!.id,
              );
              onEdit(summary);
            },
            onDelete: () {
              final summary = records.firstWhere(
                (item) => item.id == selected!.id,
              );
              onDelete(summary);
            },
          );

    return Column(
      children: [
        _TopBar(
          title: '保险库',
          mobile: mobile,
          onLock: onLock,
          searchHint: '搜索保险库…',
          onSearch: onQueryChanged,
          action: FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建项目'),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!compact)
                _CategoryColumn(
                  records: records,
                  selectedCategory: categoryFilter,
                  onCategorySelected: onCategoryChanged,
                ),
              if (!mobile || selected == null)
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border(right: BorderSide(color: _outline)),
                    ),
                    child: filtered.isEmpty
                        ? const _EmptyState(
                            icon: Icons.key_off_outlined,
                            title: '没有匹配的项目',
                            detail: '新建项目或尝试其他搜索词。',
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final record = filtered[index];
                              final active = record.id == selected?.id;
                              return _RecordTile(
                                record: record,
                                active: active,
                                onTap: () => onSelect(record),
                              );
                            },
                          ),
                  ),
                ),
              if (mobile && selected != null)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextButton.icon(
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('返回保险库'),
                      ),
                      Expanded(child: details),
                    ],
                  ),
                ),
              if (!mobile) SizedBox(width: compact ? 320 : 350, child: details),
            ],
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    this.searchHint,
    this.onSearch,
    this.action,
    this.mobile = false,
    this.onLock,
  });

  final String title;
  final String? searchHint;
  final ValueChanged<String>? onSearch;
  final Widget? action;
  final bool mobile;
  final VoidCallback? onLock;

  @override
  Widget build(BuildContext context) {
    final heading = Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: mobile ? 20 : 23,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        if (mobile && onLock != null)
          IconButton(
            tooltip: '锁定保险库',
            onPressed: onLock,
            icon: const Icon(Icons.lock_outline),
          ),
        if (mobile && action != null) ...[const SizedBox(width: 8), action!],
      ],
    );
    if (mobile) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _outline)),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              heading,
              if (searchHint != null) ...[
                const SizedBox(height: 8),
                TextField(
                  onChanged: onSearch,
                  decoration: InputDecoration(
                    hintText: searchHint,
                    prefixIcon: const Icon(Icons.search, size: 19),
                    isDense: true,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Container(
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _outline)),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          if (searchHint != null) ...[
            Flexible(
              flex: 2,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 320),
                child: TextField(
                  onChanged: onSearch,
                  decoration: InputDecoration(
                    hintText: searchHint,
                    prefixIcon: const Icon(Icons.search, size: 19),
                    isDense: true,
                  ),
                ),
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(width: 12), action!],
        ],
      ),
    );
  }
}

class _CategoryColumn extends StatelessWidget {
  const _CategoryColumn({
    required this.records,
    required this.selectedCategory,
    required this.onCategorySelected,
  });

  final List<VaultItemSummary> records;
  final VaultCategoryFilter selectedCategory;
  final ValueChanged<VaultCategoryFilter> onCategorySelected;

  @override
  Widget build(BuildContext context) {
    final loginsCount = records.where((r) => r.hasPassword).length;
    final totpCount = records.where((r) => r.hasTotp).length;
    final passkeysCount = records.where((r) => r.hasPasskey).length;

    final categories = <(VaultCategoryFilter, IconData, String, int)>[
      (VaultCategoryFilter.all, Icons.dataset_outlined, '全部项目', records.length),
      (VaultCategoryFilter.logins, Icons.key_outlined, '登录密码', loginsCount),
      (VaultCategoryFilter.totp, Icons.timer_outlined, 'TOTP 凭据', totpCount),
      (VaultCategoryFilter.passkeys, Icons.fingerprint, '通行密钥', passkeysCount),
    ];

    return Container(
      width: 210,
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: _outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 8, 8, 10),
            child: Text(
              '分类',
              style: TextStyle(
                fontSize: 11,
                color: _muted,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),
          for (final cat in categories)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: selectedCategory == cat.$1
                    ? _surfaceHigh
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: () => onCategorySelected(cat.$1),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          cat.$2,
                          size: 17,
                          color: selectedCategory == cat.$1 ? _text : _muted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            cat.$3,
                            style: TextStyle(
                              fontSize: 13,
                              color: selectedCategory == cat.$1
                                  ? _text
                                  : _muted,
                              fontWeight: selectedCategory == cat.$1
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: selectedCategory == cat.$1
                                ? _surfaceHighest
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${cat.$4}',
                            style: TextStyle(
                              fontSize: 11,
                              color: selectedCategory == cat.$1
                                  ? _text
                                  : _muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemAvatar extends StatelessWidget {
  const _ItemAvatar({required this.title, this.website = '', this.size = 38});

  final String title;
  final String website;
  final double size;

  static const _palette = [
    Color(0xFF312E81),
    Color(0xFF065F46),
    Color(0xFF581C87),
    Color(0xFF831843),
    Color(0xFF1E3A8A),
    Color(0xFF701A75),
    Color(0xFF134E4A),
    Color(0xFF7C2D12),
  ];

  @override
  Widget build(BuildContext context) {
    final cleanTitle = title.trim();
    final cleanWebsite = website.trim();
    String displayChar = '';
    if (cleanTitle.isNotEmpty) {
      displayChar = cleanTitle.substring(0, 1).toUpperCase();
    } else if (cleanWebsite.isNotEmpty) {
      displayChar = cleanWebsite.substring(0, 1).toUpperCase();
    }

    final hash = (cleanTitle.isEmpty ? cleanWebsite : cleanTitle).hashCode
        .abs();
    final bgColor = _palette[hash % _palette.length];

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: const Color(0x22FFFFFF)),
      ),
      child: Center(
        child: displayChar.isNotEmpty
            ? Text(
                displayChar,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.45,
                  fontWeight: FontWeight.w700,
                ),
              )
            : Icon(
                Icons.public,
                size: size * 0.48,
                color: const Color(0xCCFFFFFF),
              ),
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.active,
    required this.onTap,
  });

  final VaultItemSummary record;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: active ? _surfaceHigh : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: active ? const Color(0x665B5BF2) : Colors.transparent,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _ItemAvatar(
                  title: record.title,
                  website: record.website,
                  size: 38,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        record.username.isNotEmpty
                            ? record.username
                            : record.website,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        children: [
                          if (record.hasPassword)
                            const _CredentialBadge(
                              icon: Icons.key_outlined,
                              label: '密码',
                            ),
                          if (record.hasTotp)
                            const _CredentialBadge(
                              icon: Icons.timer_outlined,
                              label: 'TOTP',
                            ),
                          if (record.hasPasskey)
                            const _CredentialBadge(
                              icon: Icons.fingerprint,
                              label: '通行密钥',
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: _muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CredentialBadge extends StatelessWidget {
  const _CredentialBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: _surfaceHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: _muted),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 10, color: _muted)),
        ],
      ),
    );
  }
}

class _RecordDetails extends StatelessWidget {
  const _RecordDetails({
    required this.record,
    required this.showPassword,
    required this.onTogglePassword,
    required this.onCopyPassword,
    required this.onCopyTotp,
    required this.onCopyUsername,
    required this.onCopyWebsite,
    required this.onEdit,
    required this.onDelete,
  });

  final VaultItem record;
  final bool showPassword;
  final VoidCallback onTogglePassword;
  final VoidCallback onCopyPassword;
  final VoidCallback onCopyTotp;
  final VoidCallback onCopyUsername;
  final VoidCallback onCopyWebsite;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    var code = '';
    if (record.hasTotp) {
      try {
        code = generateTotp(
          record.totpSecret,
          period: record.totpPeriod,
          digits: record.totpDigits,
          algorithm: record.totpAlgorithm,
        );
      } on FormatException {
        code = '无效密钥';
      }
    }
    final remaining = totpRemainingSeconds(period: record.totpPeriod);
    final isWarning = remaining <= 5;
    final progressColor = isWarning ? const Color(0xFFFF5252) : _success;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            _ItemAvatar(title: record.title, website: record.website, size: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    record.website.isEmpty ? '未设置网站' : record.website,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
            ),
          ],
        ),
        if (record.hasPassword) ...[
          const SizedBox(height: 24),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle(icon: Icons.key_outlined, title: '登录凭据'),
                const Divider(height: 26),
                _Field(
                  label: '用户名',
                  value: record.username.isEmpty ? '—' : record.username,
                  onCopy: record.username.isNotEmpty ? onCopyUsername : null,
                ),
                const Divider(height: 26),
                _Field(
                  label: '密码',
                  value: showPassword ? record.password : '••••••••••••',
                  trailing: IconButton(
                    onPressed: onTogglePassword,
                    icon: Icon(
                      showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onCopyPassword,
                    icon: const Icon(Icons.copy_outlined, size: 17),
                    label: const Text('复制密码'),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (record.hasTotp) ...[
          const SizedBox(height: 14),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle(
                  icon: Icons.timer_outlined,
                  title: 'TOTP 凭据',
                ),
                const SizedBox(height: 20),
                Center(
                  child: Text(
                    code,
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 6,
                      color: isWarning && code != '无效密钥'
                          ? const Color(0xFFFF6B6B)
                          : _text,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: remaining / record.totpPeriod,
                    color: progressColor,
                    backgroundColor: progressColor.withValues(alpha: 0.15),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    '$remaining 秒后更新',
                    style: TextStyle(
                      color: isWarning ? const Color(0xFFFF6B6B) : _muted,
                      fontWeight: isWarning
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                const Divider(height: 28),
                _Field(
                  label: '账号',
                  value: record.username.isEmpty ? '—' : record.username,
                  onCopy: record.username.isNotEmpty ? onCopyUsername : null,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: code == '无效密钥' ? null : onCopyTotp,
                    icon: const Icon(Icons.copy_outlined, size: 17),
                    label: const Text('复制验证码'),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (record.hasPasskey) ...[
          const SizedBox(height: 14),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle(icon: Icons.fingerprint, title: '通行密钥'),
                const Divider(height: 26),
                for (
                  var index = 0;
                  index < record.passkeys.length;
                  index++
                ) ...[
                  _Field(
                    label: '网站',
                    value: record.passkeys[index].relyingPartyId,
                  ),
                  const SizedBox(height: 10),
                  _Field(label: '账号', value: record.passkeys[index].userName),
                  if (index + 1 < record.passkeys.length)
                    const Divider(height: 26),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        _Panel(
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: _success, size: 18),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('本地加密存储', style: TextStyle(fontSize: 13)),
              ),
              TextButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 17),
                label: const Text('删除'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DashboardPage extends StatelessWidget {
  const _DashboardPage({
    required this.mobile,
    required this.recordCount,
    required this.passwordAudit,
    required this.onAdd,
    required this.onGeneratePassword,
    required this.onOpenVault,
    required this.onLock,
  });

  final bool mobile;
  final int recordCount;
  final PasswordAudit passwordAudit;
  final VoidCallback onAdd;
  final VoidCallback onGeneratePassword;
  final VoidCallback onOpenVault;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(title: '仪表盘', mobile: mobile, onLock: onLock),
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(mobile ? 16 : 28),
            children: [
              Wrap(
                spacing: 18,
                runSpacing: 18,
                children: [
                  SizedBox(
                    width: mobile ? double.infinity : 520,
                    child: _Panel(
                      padding: const EdgeInsets.all(28),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '保险库保护状态',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  '本地保险库已解锁，数据使用 Argon2id 与 XChaCha20-Poly1305 保护。',
                                  style: TextStyle(color: _muted, height: 1.5),
                                ),
                                SizedBox(height: 16),
                                _StatusChip(label: '本地保护已启用', color: _success),
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          Container(
                            width: 92,
                            height: 92,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: _success, width: 7),
                            ),
                            child: const Icon(
                              Icons.shield_outlined,
                              color: _success,
                              size: 34,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: mobile ? double.infinity : 300,
                    child: _Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '快速操作',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 14),
                          _QuickAction(
                            icon: Icons.add,
                            title: '新建项目',
                            detail: '添加密码和/或 TOTP',
                            onTap: onAdd,
                          ),
                          _QuickAction(
                            icon: Icons.lock_outline,
                            title: '打开保险库',
                            detail: '$recordCount 个保险库项目',
                            onTap: onOpenVault,
                          ),
                          _QuickAction(
                            icon: Icons.password_outlined,
                            title: '生成安全密码',
                            detail: '使用系统安全随机源',
                            onTap: onGeneratePassword,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 18,
                runSpacing: 18,
                children: [
                  _MetricCard(
                    width: mobile ? double.infinity : 250,
                    icon: Icons.login,
                    value: '$recordCount',
                    label: '保险库项目',
                  ),
                  _MetricCard(
                    width: mobile ? double.infinity : 250,
                    icon: Icons.cloud_off_outlined,
                    value: '本地',
                    label: '无云端存储',
                  ),
                  _MetricCard(
                    width: mobile ? double.infinity : 250,
                    icon: Icons.health_and_safety_outlined,
                    value: '${passwordAudit.score}',
                    label: '密码健康分',
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SecurityPage extends StatelessWidget {
  const _SecurityPage({
    required this.audit,
    required this.mobile,
    required this.onLock,
  });

  final PasswordAudit audit;
  final bool mobile;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(title: '安全中心', mobile: mobile, onLock: onLock),
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(mobile ? 16 : 28),
            children: [
              const Text('监控并强化你的本地保险库。', style: TextStyle(color: _muted)),
              const SizedBox(height: 22),
              _Panel(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '安全健康检查',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _StatusChip(
                          label: audit.weak == 0 && audit.reused == 0
                              ? '未发现密码问题'
                              : '需要处理',
                          color: audit.weak == 0 && audit.reused == 0
                              ? _success
                              : _warning,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: [
                        _SecurityFact(
                          width: mobile ? 130 : 180,
                          icon: Icons.enhanced_encryption_outlined,
                          title: '本地加密',
                          value: 'XChaCha20',
                        ),
                        _SecurityFact(
                          width: mobile ? 130 : 180,
                          icon: Icons.memory_outlined,
                          title: '密钥派生',
                          value: 'Argon2id',
                        ),
                        _SecurityFact(
                          width: mobile ? 130 : 180,
                          icon: Icons.lock_clock_outlined,
                          title: '后台保护',
                          value: '自动锁定',
                        ),
                        _SecurityFact(
                          width: mobile ? 130 : 180,
                          icon: Icons.wifi_off_outlined,
                          title: '云端暴露',
                          value: '无',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 18,
                runSpacing: 18,
                children: [
                  _MetricCard(
                    width: mobile ? double.infinity : 250,
                    icon: Icons.password_outlined,
                    value: '${audit.total}',
                    label: '已审计密码',
                  ),
                  _MetricCard(
                    width: mobile ? double.infinity : 250,
                    icon: Icons.warning_amber_outlined,
                    value: '${audit.weak}',
                    label: '弱密码',
                  ),
                  _MetricCard(
                    width: mobile ? double.infinity : 250,
                    icon: Icons.copy_all_outlined,
                    value: '${audit.reused}',
                    label: '复用密码条目',
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SharingPage extends StatelessWidget {
  const _SharingPage({
    required this.mobile,
    required this.peers,
    required this.onPair,
    required this.onSync,
    required this.onRevoke,
    required this.onLock,
  });

  final bool mobile;
  final List<LanPeer> peers;
  final ValueChanged<LanPeer> onPair;
  final ValueChanged<LanPeer> onSync;
  final ValueChanged<LanPeer> onRevoke;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(title: '局域网同步', mobile: mobile, onLock: onLock),
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(mobile ? 16 : 28),
            children: [
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionTitle(
                      icon: Icons.lan_outlined,
                      title: '同一局域网设备',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '通过 TLS 直接连接，不使用云端或互联网中继。',
                      style: TextStyle(color: _muted),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '仅“设置 → 允许配对”开启的设备会被发现。',
                      style: TextStyle(color: _muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (peers.isEmpty)
                const _EmptyState(
                  icon: Icons.radar,
                  title: '正在发现设备',
                  detail: '请在另一台设备的设置中开启“允许配对”，并连接相同局域网。',
                )
              else
                ...peers.map(
                  (peer) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _Panel(
                      child: Row(
                        children: [
                          const Icon(Icons.devices_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('设备 ${peer.id.substring(0, 8)}'),
                                Text(
                                  '${peer.host}:${peer.port}',
                                  style: const TextStyle(color: _muted),
                                ),
                              ],
                            ),
                          ),
                          if (peer.paired) ...[
                            TextButton(
                              onPressed: () => onSync(peer),
                              child: const Text('立即同步'),
                            ),
                            TextButton(
                              onPressed: () => onRevoke(peer),
                              child: const Text('移除'),
                            ),
                          ] else
                            FilledButton(
                              onPressed: () => onPair(peer),
                              child: const Text('配对'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.mobile,
    required this.onImport,
    required this.onEnableAutoFill,
    required this.onChangeMasterPassword,
    required this.onEnableQuickUnlock,
    required this.quickUnlockAvailable,
    required this.autoLockDelay,
    required this.onAutoLockDelayChanged,
    required this.pairingAllowed,
    required this.onPairingAllowedChanged,
    required this.onLock,
  });

  final bool mobile;
  final VoidCallback onImport;
  final VoidCallback onEnableAutoFill;
  final VoidCallback onChangeMasterPassword;
  final VoidCallback onEnableQuickUnlock;
  final bool quickUnlockAvailable;
  final AutoLockDelay autoLockDelay;
  final ValueChanged<AutoLockDelay> onAutoLockDelayChanged;
  final bool pairingAllowed;
  final ValueChanged<bool> onPairingAllowedChanged;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(
          title: mobile ? '设置' : '设置与数字遗产',
          mobile: mobile,
          onLock: onLock,
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(mobile ? 16 : 28),
            children: [
              const Text('管理保险库安全、系统集成和恢复选项。', style: TextStyle(color: _muted)),
              const SizedBox(height: 22),
              Wrap(
                spacing: 18,
                runSpacing: 18,
                crossAxisAlignment: WrapCrossAlignment.start,
                children: [
                  SizedBox(
                    width: mobile ? double.infinity : 610,
                    child: Column(
                      children: [
                        _Panel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _SectionTitle(
                                icon: Icons.shield_outlined,
                                title: '账户安全',
                              ),
                              const Divider(height: 28),
                              _SettingRow(
                                title: '主密码',
                                detail: '仅重新封装保险库密钥',
                                actionLabel: '修改',
                                onTap: onChangeMasterPassword,
                              ),
                              const Divider(height: 24),
                              _SettingRow(
                                title: '设备快速解锁',
                                detail: quickUnlockAvailable
                                    ? '已启用，可使用系统生物识别或屏幕锁'
                                    : '未启用，使用系统生物识别或屏幕锁',
                                actionLabel: quickUnlockAvailable
                                    ? '重新启用'
                                    : '启用',
                                onTap: onEnableQuickUnlock,
                              ),
                              const Divider(height: 24),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('自动锁定'),
                                subtitle: Text(
                                  autoLockDelay == AutoLockDelay.never
                                      ? '退到后台时保持解锁；退出应用仍会锁定'
                                      : '退到后台超过所选时间后锁定保险库',
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: DropdownButton<AutoLockDelay>(
                                  value: autoLockDelay,
                                  onChanged: (delay) {
                                    if (delay != null) {
                                      onAutoLockDelayChanged(delay);
                                    }
                                  },
                                  items: AutoLockDelay.values
                                      .map(
                                        (delay) => DropdownMenuItem(
                                          value: delay,
                                          child: Text(delay.label),
                                        ),
                                      )
                                      .toList(growable: false),
                                ),
                              ),
                              const Divider(height: 24),
                              _SettingRow(
                                title: 'Apple 密码导入',
                                detail: 'macOS 26+ Credential Exchange',
                                actionLabel: '导入说明',
                                onTap: onImport,
                              ),
                              const Divider(height: 24),
                              _SettingRow(
                                title: '系统自动填充',
                                detail:
                                    'macOS AutoFill / Android 14+ Credential Manager',
                                actionLabel: '设置',
                                onTap: onEnableAutoFill,
                              ),
                              const Divider(height: 24),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('允许配对'),
                                subtitle: Text(
                                  pairingAllowed
                                      ? '已开启，其他局域网设备可以发现本机'
                                      : '已关闭，本机不会出现在设备搜索结果中',
                                  style: const TextStyle(color: _muted),
                                ),
                                value: pairingAllowed,
                                onChanged: onPairingAllowedChanged,
                              ),
                              const Divider(height: 24),
                              const _SettingRow(
                                title: '恢复工具包',
                                detail: '离线恢复码尚未实现',
                                actionLabel: '即将支持',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        const _Panel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _SectionTitle(
                                icon: Icons.family_restroom_outlined,
                                title: '数字遗产',
                              ),
                              SizedBox(height: 12),
                              Text(
                                '纯局域网架构没有可信的持续在线执行者，因此第一版不提供自动遗产授权。',
                                style: TextStyle(color: _muted, height: 1.5),
                              ),
                              SizedBox(height: 14),
                              _StatusChip(label: '未启用', color: _warning),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: mobile ? double.infinity : 320,
                    child: const _Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SectionTitle(icon: Icons.tune, title: '高级'),
                          Divider(height: 28),
                          _SettingRow(
                            title: 'Argon2id KDF',
                            detail: '参数保存在保险库头中',
                            actionLabel: '已启用',
                          ),
                          Divider(height: 24),
                          _SettingRow(
                            title: '硬件安全密钥',
                            detail: 'YubiKey 支持尚未实现',
                            actionLabel: '即将支持',
                          ),
                          SizedBox(height: 20),
                          Text(
                            '零知识本地架构',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Getfor 无法重置主密码。丢失主密码后，当前版本无法恢复保险库。',
                            style: TextStyle(color: _muted, height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(18)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _outline),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33010F1F),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      // ListTile ink must paint above the panel's decoration.
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    this.trailing,
    this.onCopy,
  });

  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final showCopy = onCopy != null && value.isNotEmpty && value != '—';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10,
                  color: _muted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 6),
              SelectableText(value, style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
        if (showCopy)
          IconButton(
            onPressed: onCopy,
            icon: const Icon(Icons.copy_outlined, size: 16),
            tooltip: '复制$label',
            visualDensity: VisualDensity.compact,
          ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: _muted),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.detail,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: _surfaceHighest,
        child: Icon(icon, size: 18, color: _text),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        detail,
        style: const TextStyle(fontSize: 11, color: _muted),
      ),
      trailing: onTap == null
          ? const Icon(Icons.schedule, size: 16, color: _muted)
          : const Icon(Icons.chevron_right, size: 17),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    this.width = 250,
    required this.icon,
    required this.value,
    required this.label,
  });

  final double width;
  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: _Panel(
        child: Row(
          children: [
            Icon(icon, color: _success),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SecurityFact extends StatelessWidget {
  const _SecurityFact({
    this.width = 180,
    required this.icon,
    required this.title,
    required this.value,
  });

  final double width;
  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surfaceHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _success, size: 20),
          const SizedBox(height: 12),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(title, style: const TextStyle(color: _muted, fontSize: 11)),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 19),
      const SizedBox(width: 10),
      Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    ],
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.detail,
    required this.actionLabel,
    this.onTap,
  });

  final String title;
  final String detail;
  final String actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(detail, style: const TextStyle(color: _muted, fontSize: 12)),
            ],
          ),
        ),
        OutlinedButton(onPressed: onTap, child: Text(actionLabel)),
      ],
    );
  }
}
