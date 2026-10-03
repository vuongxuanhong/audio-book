import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';

/// Checks the app version at launch and whenever the app comes back to the
/// foreground. A version below the server's minimum replaces the whole app
/// with an update screen; one below the latest gets a dismissible dialog.
///
/// Sits in [MaterialApp.builder], above the Navigator, so the block covers
/// every route; the dialog goes through [navigatorKey] for that reason.
class UpdateGate extends StatefulWidget {
  const UpdateGate({
    super.key,
    required this.service,
    required this.navigatorKey,
    required this.child,
  });

  final AppUpdateService service;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> with WidgetsBindingObserver {
  UpdateCheck? _required;
  bool _dialogOpen = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    final result = await widget.service.check();
    _checking = false;
    if (!mounted) return;

    switch (result.kind) {
      case UpdateKind.required:
        setState(() => _required = result);
      case UpdateKind.optional:
        // The minimum may have been lowered again since the last check.
        if (_required != null) setState(() => _required = null);
        _showOptional(result);
      case UpdateKind.none:
        if (_required != null) setState(() => _required = null);
    }
  }

  Future<void> _showOptional(UpdateCheck update) async {
    final context = widget.navigatorKey.currentContext;
    if (_dialogOpen || context == null) return;
    _dialogOpen = true;
    final later = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đã có phiên bản mới'),
        content: Text(
          'Phiên bản ${update.latestVersion} đã sẵn sàng. '
          'Cập nhật để dùng các tính năng và bản sửa lỗi mới nhất.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Để sau'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context, false);
              _openStore(update.storeUrl);
            },
            child: const Text('Cập nhật'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (later ?? true) await widget.service.skip(update.latestVersion);
  }

  @override
  Widget build(BuildContext context) {
    final required = _required;
    if (required == null) return widget.child;
    return _UpdateRequiredScreen(update: required);
  }
}

Future<void> _openStore(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || url.isEmpty) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _UpdateRequiredScreen extends StatelessWidget {
  const _UpdateRequiredScreen({required this.update});

  final UpdateCheck update;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/icon/about_icon.png',
                    width: 96,
                    height: 96,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Cần cập nhật ứng dụng',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Phiên bản này không còn được hỗ trợ. Vui lòng cập nhật lên '
                'phiên bản ${update.latestVersion} để tiếp tục đọc và nghe '
                'truyện.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: update.storeUrl.isEmpty
                    ? null
                    : () => _openStore(update.storeUrl),
                child: const Text('Cập nhật ngay'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
