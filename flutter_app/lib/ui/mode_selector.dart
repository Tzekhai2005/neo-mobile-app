import 'package:flutter/material.dart';
import 'standalone_screen.dart';
import 'webview_shell.dart';

/// Home screen: user picks how they want to connect.
class ModeSelector extends StatelessWidget {
  const ModeSelector({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090c15),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),

              // Brand header
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0f1422),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: const Color(0x4400b4d8), width: 1.5),
                    ),
                    child: const Icon(Icons.graphic_eq_rounded, color: Color(0xFF00b4d8), size: 22),
                  ),
                  const SizedBox(width: 14),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Neo Ear-EEG',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
                      Text('Clinical Companion v2',
                          style: TextStyle(fontSize: 11, color: Color(0xFF64748b), fontWeight: FontWeight.w600)),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 40),

              const Text(
                'SELECT CONNECTION MODE',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF475569),
                    letterSpacing: 1.0),
              ),
              const SizedBox(height: 14),

              // ── MODE 1: Standalone / Direct Hardware ──────────────────────
              _ModeCard(
                badge: 'STANDALONE',
                badgeColor: const Color(0xFF10b981),
                title: 'Direct Hardware',
                subtitle: 'Phone connects directly to Neo headband.\nNo laptop required.',
                bullets: [
                  '📡  Auto-discovers Neo device on Wi-Fi',
                  '⚡  Streams real EEG @ 250 SPS via UDP',
                  '🔋  Works phone + hardware only',
                  '🏥  Use for clinical testing & field use',
                ],
                accentColor: const Color(0xFF10b981),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const StandaloneScreen()),
                ),
              ),

              const SizedBox(height: 16),

              // ── MODE 2: Server Companion ──────────────────────────────────
              _ModeCard(
                badge: 'COMPANION',
                badgeColor: const Color(0xFF00b4d8),
                title: 'Mac Server Bridge',
                subtitle: 'Connects to server.py running on your Mac.\nBest for demos & pitch rehearsal.',
                bullets: [
                  '💻  Mac runs server.py on same Wi-Fi',
                  '📊  Full 4-tab clinical UI (PDF reports)',
                  '🧠  Seizure demo & bench triggers',
                  '🎯  Use for investor demos & stage',
                ],
                accentColor: const Color(0xFF00b4d8),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const WebViewShell()),
                ),
              ),

              const Spacer(),

              // Footer
              Center(
                child: Text(
                  'SeizeIT2 Clinical Trial Aligned  •  ADS1292R 250 SPS 24-bit',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10, color: Color(0xFF334155)),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final String badge;
  final Color badgeColor;
  final String title;
  final String subtitle;
  final List<String> bullets;
  final Color accentColor;
  final VoidCallback onTap;

  const _ModeCard({
    required this.badge,
    required this.badgeColor,
    required this.title,
    required this.subtitle,
    required this.bullets,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF0f1422),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accentColor.withOpacity(0.3), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: badgeColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: badgeColor.withOpacity(0.4)),
                  ),
                  child: Text(badge,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: badgeColor,
                          letterSpacing: 0.5)),
                ),
                Icon(Icons.arrow_forward_ios_rounded, size: 14, color: accentColor.withOpacity(0.6)),
              ],
            ),
            const SizedBox(height: 10),
            Text(title,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 5),
            Text(subtitle,
                style: const TextStyle(fontSize: 12, color: Color(0xFF94a3b8), height: 1.45)),
            const SizedBox(height: 12),
            ...bullets.map((b) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(b, style: const TextStyle(fontSize: 12, color: Color(0xFF64748b))),
            )),
          ],
        ),
      ),
    );
  }
}
