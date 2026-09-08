import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Bottom sheet that scans a barcode via camera (mobile) or listens for
/// USB hardware scanner keystrokes (web / desktop counter).
///
/// Calls [onBarcodeScanned] once with the raw barcode string, then closes.
class BarcodeScannerModal extends StatefulWidget {
  final void Function(String barcode) onBarcodeScanned;

  const BarcodeScannerModal({super.key, required this.onBarcodeScanned});

  @override
  State<BarcodeScannerModal> createState() => _BarcodeScannerModalState();
}

class _BarcodeScannerModalState extends State<BarcodeScannerModal> {
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _scanned = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _handleDetected(String raw) {
    if (_scanned) return;
    _scanned = true;
    widget.onBarcodeScanned(raw);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 440,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Scan Product Barcode',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: MobileScanner(
                controller: _scanner,
                onDetect: (capture) {
                  for (final barcode in capture.barcodes) {
                    if (barcode.rawValue != null) {
                      _handleDetected(barcode.rawValue!);
                      break;
                    }
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('Or use a USB barcode scanner — it types the code automatically.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// USB / WEB HARDWARE SCANNER FALLBACK
//
// Wrap any screen widget with this to intercept rapid keyboard input from
// a USB barcode reader (which fires characters < 20ms apart then sends ENTER).
// ---------------------------------------------------------------------------
class HardwareBarcodeListener extends StatefulWidget {
  final Widget child;
  final void Function(String barcode) onBarcodeScanned;

  const HardwareBarcodeListener({
    super.key,
    required this.child,
    required this.onBarcodeScanned,
  });

  @override
  State<HardwareBarcodeListener> createState() =>
      _HardwareBarcodeListenerState();
}

class _HardwareBarcodeListenerState extends State<HardwareBarcodeListener> {
  final StringBuffer _buf = StringBuffer();
  DateTime? _lastKey;

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final now = DateTime.now();

    // Human typing is slower than 100ms per character; scanner is < 20ms.
    if (_lastKey != null &&
        now.difference(_lastKey!).inMilliseconds > 100) {
      _buf.clear();
    }
    _lastKey = now;

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      final code = _buf.toString().trim();
      if (code.isNotEmpty) {
        widget.onBarcodeScanned(code);
        _buf.clear();
      }
    } else if (event.character != null) {
      _buf.write(event.character);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}
