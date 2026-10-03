import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _appName = 'Tàng Kinh Các';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Giới thiệu')),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          final info = snapshot.data;
          final version =
              info == null ? '' : '${info.version} (${info.buildNumber})';

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 24),
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
              const SizedBox(height: 16),
              Text(
                _appName,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Phiên bản $version',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Text(
                  'Đọc và nghe truyện tiếng Việt. Giọng đọc được tổng hợp '
                  'ngay trên máy.',
                  textAlign: TextAlign.center,
                ),
              ),
              const Divider(height: 32),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Giấy phép mã nguồn mở'),
                subtitle:
                    const Text('Thư viện ứng dụng sử dụng'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: _appName,
                  applicationVersion: version,
                  applicationIcon: Padding(
                    padding: const EdgeInsets.all(8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        'assets/icon/about_icon.png',
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
