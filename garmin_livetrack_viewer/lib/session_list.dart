part of 'main.dart';

/// Running and recently finished LiveTracks, so a session can still be opened
/// when its push notification never arrived. Unlocked by the push
/// registration token, whose holders receive every session's link by
/// notification anyway. Owned by the map page, which also uses it to pick a
/// running session when none is selected.
class _SessionListModel extends ChangeNotifier {
  static const _refreshInterval = Duration(seconds: 20);

  Timer? _timer;
  bool _loading = false;
  bool _disposed = false;

  /// Null until the first successful load.
  List<Map<String, dynamic>>? sessions;
  String? error;
  bool tokenRejected = false;

  bool get hasToken => _push.token != null;

  void start() {
    _push.service.addListener(_onTokenChanged);
    load();
    _timer = Timer.periodic(_refreshInterval, (_) => load());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _push.service.removeListener(_onTokenChanged);
    super.dispose();
  }

  void _onTokenChanged() {
    sessions = null;
    error = null;
    tokenRejected = false;
    notifyListeners();
    load();
  }

  Future<void> load() async {
    final token = _push.token;
    if (token == null || _loading) return;
    _loading = true;
    try {
      final response = await http.get(
        _apiUri('/push/sessions'),
        headers: {'X-Push-Token': token},
      );
      if (_disposed) return;
      if (response.statusCode == 403) {
        tokenRejected = true;
        sessions = null;
      } else if (response.statusCode != 200) {
        throw _ApiException(response.statusCode);
      } else {
        sessions = (jsonDecode(response.body) as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .toList();
        error = null;
        tokenRejected = false;
      }
    } catch (e) {
      log('$e');
      if (_disposed) return;
      error = 'Cannot reach API: $e';
    } finally {
      _loading = false;
    }
    if (!_disposed) notifyListeners();
  }
}

/// The session list, shown as a collapsible side panel on wide screens and
/// as a full-screen menu on phones.
class _SessionListPanel extends StatelessWidget {
  const _SessionListPanel({
    required this.model,
    required this.selectedId,
    required this.onSelect,
    required this.onEnterToken,
  });

  final _SessionListModel model;
  final String? selectedId;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final VoidCallback onEnterToken;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (!model.hasToken || model.tokenRejected) {
      return _ListMessage(
        icon: Icons.key,
        title: model.tokenRejected
            ? 'Registration token not accepted'
            : 'Registration token needed',
        text:
            'Open the invite link you received once on this device, or enter '
            'the registration token.',
        action: FilledButton(
          onPressed: onEnterToken,
          child: const Text('Enter token'),
        ),
      );
    }
    final sessions = model.sessions;
    if (sessions == null) {
      final error = model.error;
      if (error == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return _ListMessage(
        icon: Icons.cloud_off,
        title: 'Cannot load LiveTracks',
        text: error,
        action: FilledButton(onPressed: model.load, child: const Text('Retry')),
      );
    }

    final live = sessions.where((s) => s['live'] == true).toList();
    final finished = sessions.where((s) => s['live'] != true).toList();
    Widget tile(Map<String, dynamic> session) => _SessionTile(
      session: session,
      selected: session['id'] == selectedId,
      onTap: () => onSelect(session),
    );
    return RefreshIndicator(
      onRefresh: model.load,
      child: ListView(
        // Always scrollable so pull-to-refresh also works on a short list.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          if (model.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                model.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (sessions.isEmpty)
            const _ListMessage(
              icon: Icons.route,
              title: 'No LiveTracks right now',
              text:
                  'Running LiveTracks and those from the last few days show '
                  'up here.',
            ),
          if (live.isNotEmpty) ...[
            const _SectionHeader('Live'),
            for (final session in live) tile(session),
          ],
          if (finished.isNotEmpty) ...[
            const _SectionHeader('Finished'),
            for (final session in finished) tile(session),
          ],
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> session;
  final bool selected;
  final VoidCallback onTap;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  // "14:32" today, "Yesterday 14:32", then "Tue 14:32" within a week.
  static String _formatWhen(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    final daysAgo = today.difference(day).inDays;
    final clock = _formatHourMinute(time);
    if (daysAgo == 0) return clock;
    if (daysAgo == 1) return 'Yesterday $clock';
    if (daysAgo < 7) return '${_weekdays[time.weekday - 1]} $clock';
    return '${_twoDigits(time.day)}.${_twoDigits(time.month)}. $clock';
  }

  String _statusText(bool live) {
    final start = _parseIsoDateTime(session['start']);
    final end = _parseIsoDateTime(session['end']);
    switch (session['state']) {
      case 'error':
        return 'Tracking failed';
      case 'stopped':
        return 'Tracking stopped';
    }
    if (live) {
      if (start == null) return 'Connecting…';
      return 'Started ${_formatWhen(start)}';
    }
    if (end != null) return 'Ended ${_formatWhen(end)}';
    if (start != null) return 'Started ${_formatWhen(start)}';
    return 'Ended';
  }

  @override
  Widget build(BuildContext context) {
    final live = session['live'] == true;
    final id = session['id']?.toString() ?? '';
    final token = session['sessionToken']?.toString() ?? '';
    final athlete = session['athleteName']?.toString().trim();
    final name = session['sessionName']?.toString().trim();
    final distance = session['distanceMeters'];
    final imageUrl = session['hasProfileImage'] == true
        ? _apiUri(
            '/trackings/$id/token/${Uri.encodeComponent(token)}/profile-image',
          ).toString()
        : null;
    final details = [
      _statusText(live),
      if (distance is num && distance > 0) _formatDistance(distance),
    ].join(' · ');
    final title = (athlete != null && athlete.isNotEmpty)
        ? athlete
        : (name != null && name.isNotEmpty ? name : 'LiveTrack');
    final showName = name != null && name.isNotEmpty && name != title;

    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      // The session currently shown on the map.
      color: selected ? colors.secondaryContainer : null,
      child: ListTile(
        selected: selected,
        selectedColor: colors.onSecondaryContainer,
        leading: _ProfileAvatar(imageUrl: imageUrl, ended: !live),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          showName ? '$name\n$details' : details,
          maxLines: showName ? 2 : 1,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: showName,
        trailing: live ? const _LiveBadge() : null,
        onTap: onTap,
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _ListMessage extends StatelessWidget {
  const _ListMessage({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });

  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
