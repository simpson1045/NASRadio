import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

/// Admin-only user management, embedded in the Settings → Account tab.
/// Lists users and lets an admin add accounts, reset passwords, change roles,
/// log a user out of all devices, or delete them.
class UserManagement extends StatefulWidget {
  const UserManagement({super.key});

  @override
  State<UserManagement> createState() => _UserManagementState();
}

class _UserManagementState extends State<UserManagement> {
  final ApiService _api = ApiService();
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  String? _error;

  int? get _myId => AuthService.instance.user?['id'] as int?;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await _api.getUsers();
      if (mounted) setState(() => _users = users);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _addUser() async {
    final usernameC = TextEditingController();
    final passwordC = TextEditingController();
    String role = 'user';
    String? dialogError;
    bool busy = false;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF0d1521),
          title: const Text('Add User'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: usernameC,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordC,
                decoration: const InputDecoration(
                  labelText: 'Password (min 8 chars)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(
                  labelText: 'Role',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'user', child: Text('User')),
                  DropdownMenuItem(value: 'admin', child: Text('Administrator')),
                ],
                onChanged: (v) => setLocal(() => role = v ?? 'user'),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 10),
                Text(dialogError!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() {
                        busy = true;
                        dialogError = null;
                      });
                      final result = await _api.createUser(
                        usernameC.text.trim(),
                        passwordC.text,
                        role,
                      );
                      if (result['success'] == true) {
                        if (context.mounted) Navigator.pop(context);
                        _snack('User "${usernameC.text.trim()}" created');
                        _load();
                      } else {
                        setLocal(() {
                          busy = false;
                          dialogError = result['error']?.toString() ?? 'Failed';
                        });
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
              ),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resetPassword(Map<String, dynamic> user) async {
    final passwordC = TextEditingController();
    String? dialogError;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF0d1521),
          title: Text('Reset password — ${user['username']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: passwordC,
                decoration: const InputDecoration(
                  labelText: 'New password (min 8 chars)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 10),
                Text(dialogError!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final result =
                    await _api.setUserPassword(user['id'] as int, passwordC.text);
                if (result['success'] == true) {
                  if (context.mounted) Navigator.pop(context);
                  _snack('Password reset for ${user['username']}');
                } else {
                  setLocal(() =>
                      dialogError = result['error']?.toString() ?? 'Failed');
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
              ),
              child: const Text('Reset'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleRole(Map<String, dynamic> user) async {
    final newRole = user['role'] == 'admin' ? 'user' : 'admin';
    final result = await _api.setUserRole(user['id'] as int, newRole);
    if (result['success'] == true) {
      _snack('${user['username']} is now ${newRole == 'admin' ? 'an administrator' : 'a user'}');
      _load();
    } else {
      _snack(result['error']?.toString() ?? 'Failed', error: true);
    }
  }

  Future<void> _revoke(Map<String, dynamic> user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0d1521),
        title: const Text('Log out everywhere'),
        content: Text(
            'Sign ${user['username']} out of all their devices? They\'ll need to log in again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final result = await _api.revokeUser(user['id'] as int);
    _snack(
      result['success'] == true
          ? '${user['username']} logged out everywhere'
          : (result['error']?.toString() ?? 'Failed'),
      error: result['success'] != true,
    );
  }

  Future<void> _delete(Map<String, dynamic> user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0d1521),
        title: Text('Delete ${user['username']}?'),
        content: const Text(
            'This permanently deletes the account and all of their playlists and favorites. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final result = await _api.deleteUser(user['id'] as int);
    if (result['success'] == true) {
      _snack('${user['username']} deleted');
      _load();
    } else {
      _snack(result['error']?.toString() ?? 'Failed', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'User Management',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF00d4ff),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _addUser,
              icon: const Icon(Icons.person_add, size: 18),
              label: const Text('Add User'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Row(
            children: [
              Expanded(
                child: Text('Error: $_error',
                    style: const TextStyle(color: Colors.red)),
              ),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          )
        else
          ..._users.map(_userTile),
      ],
    );
  }

  Widget _userTile(Map<String, dynamic> user) {
    final isAdmin = user['role'] == 'admin';
    final isMe = user['id'] == _myId;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isAdmin ? Icons.shield : Icons.person,
            color: isAdmin ? Colors.amber : Colors.grey,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      user['username']?.toString() ?? '',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      const Text('(you)',
                          style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ],
                ),
                Text(
                  isAdmin ? 'Administrator' : 'User',
                  style: TextStyle(
                    fontSize: 11,
                    color: isAdmin ? Colors.amber : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.grey),
            color: const Color(0xFF1a2332),
            onSelected: (action) {
              switch (action) {
                case 'password':
                  _resetPassword(user);
                  break;
                case 'role':
                  _toggleRole(user);
                  break;
                case 'revoke':
                  _revoke(user);
                  break;
                case 'delete':
                  _delete(user);
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'password',
                child: Text('Reset password'),
              ),
              PopupMenuItem(
                value: 'role',
                child: Text(isAdmin ? 'Make user' : 'Make admin'),
              ),
              const PopupMenuItem(
                value: 'revoke',
                child: Text('Log out everywhere'),
              ),
              if (!isMe)
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete', style: TextStyle(color: Colors.redAccent)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
