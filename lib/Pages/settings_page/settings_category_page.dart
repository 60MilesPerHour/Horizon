import 'package:flutter/material.dart';

/// Scaffold for a settings category.
///
/// The section widgets are unchanged — they were already self-contained, they
/// were just all stacked on one page. This wraps one in its own route so the
/// root page can be a scannable list instead of a wall of fields.
class SettingsCategoryPage extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingsCategoryPage({
    super.key,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [...children, const SizedBox(height: 32)],
      ),
    );
  }
}

/// A row on the root settings page.
class SettingsCategoryTile extends StatelessWidget {
  final IconData icon;
  final String title;

  /// Says what's inside, so the category doesn't have to be opened to find
  /// out — the point of splitting the page is fewer dead ends, not more.
  final String subtitle;

  final WidgetBuilder pageBuilder;

  const SettingsCategoryTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.pageBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: pageBuilder),
        ),
      ),
    );
  }
}
