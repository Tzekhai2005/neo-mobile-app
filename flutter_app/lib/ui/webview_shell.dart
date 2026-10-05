import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _kDefaultPort = 8080;
const _kPrefServerHost = 'server_host';

class WebViewShell extends StatefulWidget {
  const WebViewShell({Key? key}) : super(key: key);

  @override
  State<WebViewShell> createState() => _WebViewShellState();
}

class _WebViewShellState extends State<WebViewShell> {
  WebViewController? _controller;
  bool _isLoading = true;
  bool _hasError = false;
  bool _showSettings = false;
  String _serverHost = '192.168.1.100'; // default guess
  String _currentUrl = '';
  final TextEditingController _ipController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPrefsAndConnect();
  }

  Future<void> _loadPrefsAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kPrefServerHost);
    if (saved != null && saved.isNotEmpty) {
      _serverHost = saved;
    }
    _ipController.text = _serverHost;
    _buildController(_serverHost);
  }

  void _buildController(String host) {
    final url = 'http://$host:$_kDefaultPort';
    setState(() {
      _currentUrl = url;
      _isLoading = true;
      _hasError = false;
    });

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF090c15))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() {
            _isLoading = true;
            _hasError = false;
          }),
          onPageFinished: (_) => setState(() => _isLoading = false),
          onWebResourceError: (err) {
            if (err.isForMainFrame == true) {
              setState(() {
                _isLoading = false;
                _hasError = true;
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(url));

    setState(() => _controller = controller);
  }

  Future<void> _saveAndConnect(String host) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefServerHost, host);
    setState(() {
      _serverHost = host;
      _showSettings = false;
    });
    _buildController(host);
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090c15),
      // We hide the system status bar tint to give the full clinical look
      appBar: PreferredSize(
        preferredSize: Size.zero,
        child: AppBar(
          backgroundColor: const Color(0xFF090c15),
          systemOverlayStyle: const SystemUiOverlayStyle(
            statusBarColor: Color(0xFF090c15),
            statusBarIconBrightness: Brightness.light,
          ),
        ),
      ),
      body: _showSettings ? _buildSettingsScreen() : _buildWebViewScreen(),
    );
  }

  Widget _buildWebViewScreen() {
    return Stack(
      children: [
        // The WebView (full screen)
        if (_controller != null && !_hasError)
          WebViewWidget(controller: _controller!),

        // Error state: server not reachable
        if (_hasError) _buildErrorScreen(),

        // Loading shimmer overlay
        if (_isLoading && !_hasError)
          Container(
            color: const Color(0xFF090c15),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Neo brand mark
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0f1422),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0x3300b4d8), width: 1.5),
                    ),
                    child: const Icon(Icons.graphic_eq_rounded, color: Color(0xFF00b4d8), size: 28),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Neo Ear-EEG',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Connecting to $_serverHost:$_kDefaultPort…',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748b)),
                  ),
                  const SizedBox(height: 28),
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00b4d8)),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Settings button (top-right floating)
        Positioned(
          top: MediaQuery.of(context).padding.top + 6,
          right: 12,
          child: GestureDetector(
            onTap: () => setState(() => _showSettings = true),
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: const Color(0x99090c15),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0x33ffffff)),
              ),
              child: const Icon(Icons.wifi_rounded, color: Colors.white70, size: 18),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorScreen() {
    return Container(
      color: const Color(0xFF090c15),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0x1AEF4444),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0x55EF4444)),
            ),
            child: const Icon(Icons.wifi_off_rounded, color: Color(0xFFEF4444), size: 40),
          ),
          const SizedBox(height: 24),
          const Text(
            'Server Not Reachable',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            'Cannot reach $_serverHost:$_kDefaultPort\n\n'
            'Make sure:\n'
            '1. Your Mac is running server.py\n'
            '2. Your phone and Mac are on the same Wi-Fi\n'
            '3. The server IP is correct',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Color(0xFF94a3b8), height: 1.6),
          ),
          const SizedBox(height: 28),
          _OutlinedBtn(
            label: '⚙  Change Server IP',
            color: const Color(0xFF00b4d8),
            onTap: () => setState(() => _showSettings = true),
          ),
          const SizedBox(height: 12),
          _OutlinedBtn(
            label: '↺  Retry Connection',
            color: const Color(0xFF94a3b8),
            onTap: () => _buildController(_serverHost),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return Container(
      color: const Color(0xFF090c15),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  GestureDetector(
                    onTap: () => setState(() => _showSettings = false),
                    child: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white70, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Connection Settings',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // Explanation card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0f1422),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x1AFFFFFF)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'HOW IT WORKS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF64748b),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _InfoRow(icon: Icons.computer_rounded, color: const Color(0xFFA855F7),
                      text: 'Run server.py on your Mac'),
                    _InfoRow(icon: Icons.wifi_rounded, color: const Color(0xFF00b4d8),
                      text: 'Both devices on same Wi-Fi'),
                    _InfoRow(icon: Icons.phone_iphone_rounded, color: const Color(0xFF10b981),
                      text: 'Enter your Mac\'s Wi-Fi IP here'),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // IP input
              const Text(
                'Mac Server IP Address',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF94a3b8)),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0f1422),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x3300b4d8)),
                ),
                child: TextField(
                  controller: _ipController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    hintText: '172.16.12.160',
                    hintStyle: TextStyle(color: Color(0xFF475569)),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    prefixIcon: Icon(Icons.lan_rounded, color: Color(0xFF00b4d8), size: 20),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'You can find the Mac IP in the server.py startup log',
                style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 24),

              _OutlinedBtn(
                label: 'Connect  →',
                color: const Color(0xFF00b4d8),
                onTap: () {
                  final h = _ipController.text.trim();
                  if (h.isNotEmpty) _saveAndConnect(h);
                },
              ),
              const SizedBox(height: 12),

              // Current connection info
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0f1422),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x1AFFFFFF)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF64748b)),
                    const SizedBox(width: 8),
                    Text(
                      'Currently: $_currentUrl',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF64748b), fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlinedBtn extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _OutlinedBtn({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _InfoRow({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 12, color: Color(0xFF94a3b8))),
        ],
      ),
    );
  }
}
