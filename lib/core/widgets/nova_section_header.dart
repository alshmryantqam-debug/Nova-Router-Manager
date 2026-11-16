import 'package:flutter/material.dart';

const Color novaCyberCyan = Color(0xFF35D7F2);
const Color novaCyberSurface = Color(0xFF101B27);
const Color novaCyberMuted = Color(0xFF8D9AB0);

/// Shared visual identity for NOVA feature workspaces.
class NovaSectionHeader extends StatelessWidget {
  const NovaSectionHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.eyebrow = 'NOVA  /  CYBER-CORE',
    this.trailing,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String eyebrow;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(13, 12, 13, 10),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(19),
          gradient: const LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [Color(0xFF12314B), Color(0xFF0B1B2D), Color(0xFF09121F)],
          ),
          border: Border.all(color: novaCyberCyan.withOpacity(0.28)),
          boxShadow: [
            BoxShadow(
              color: novaCyberCyan.withOpacity(0.08),
              blurRadius: 22,
              spreadRadius: -5,
            ),
          ],
        ),
        child: Stack(
          children: [
            PositionedDirectional(
              end: -22,
              top: -30,
              child: Icon(icon, size: 112, color: novaCyberCyan.withOpacity(0.055)),
            ),
            Row(
              children: [
                Container(
                  width: 43,
                  height: 43,
                  decoration: BoxDecoration(
                    color: novaCyberCyan.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: novaCyberCyan.withOpacity(0.30)),
                  ),
                  child: Icon(icon, color: novaCyberCyan, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eyebrow,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          color: novaCyberCyan.withOpacity(0.82),
                          fontSize: 8,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: novaCyberMuted,
                          fontSize: 10,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 6),
                  trailing!,
                ],
              ],
            ),
          ],
        ),
      );
}
