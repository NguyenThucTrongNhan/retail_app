import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/product.dart';

/// Camera viewfinder that captures a product photo and sends it to the
/// Python FastAPI CLIP visual search service (port 8081).
///
/// On a match the bottom sheet shows name, SKU, price, and confidence.
/// "Add to Total" calls [onAddToBasket] to wire into the Basket Calculator.
///
/// Note: requires real camera hardware — use physical Android/iOS device.
/// flutter run -d chrome will show "No camera detected" gracefully.
class VisualSearchScreen extends StatefulWidget {
  final void Function(Product) onAddToBasket;

  const VisualSearchScreen({
    super.key,
    required this.onAddToBasket,
  });

  @override
  State<VisualSearchScreen> createState() => _VisualSearchScreenState();
}

class _VisualSearchScreenState extends State<VisualSearchScreen> {
  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  Future<void>? _initFuture;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      final back = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      _controller = CameraController(
        back,
        ResolutionPreset.medium, // 720p balances CLIP accuracy with upload speed
        enableAudio: false,
      );
      _initFuture = _controller!.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      // Web / emulator — camera not available; handled in build().
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // CAPTURE → EMBED → MATCH
  // ---------------------------------------------------------------------------
  Future<void> _captureAndSearch() async {
    if (_isSearching || _controller == null) return;
    setState(() => _isSearching = true);

    try {
      await _initFuture;
      final photo = await _controller!.takePicture();

      final visionUrl = await AppConfig.visionBaseUrl(); // C6: dynamic URL
      final uri = Uri.parse('$visionUrl/api/v1/search/visual?top_k=3');
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', photo.path));

      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final matches = List<Map<String, dynamic>>.from(
          (data['matches'] as List).map((m) => m as Map<String, dynamic>),
        );
        if (mounted && matches.isNotEmpty) {
          _showMatchSheet(matches.first);
        } else if (mounted) {
          _snack('No matching product found in catalog.');
        }
      } else {
        _snack('Vision service error: HTTP ${response.statusCode}');
      }
    } catch (e) {
      _snack('Search failed: $e');
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // ---------------------------------------------------------------------------
  // RESULT BOTTOM SHEET
  // ---------------------------------------------------------------------------
  void _showMatchSheet(Map<String, dynamic> match) {
    final confidence = ((match['confidence'] as num).toDouble() * 100);
    final price = (match['price'] as num).toDouble();

    // Reconstruct a Product-like object from the JSON for the basket callback.
    final product = Product()
      ..id = match['id'] as String
      ..sku = match['sku'] as String
      ..name = match['name'] as String
      ..price = price
      ..stockQuantity = match['stock_quantity'] as int
      ..imageUrl = match['image_url'] as String?
      ..version = 0
      ..updatedAt = '';

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: 270,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Visual Lens Match',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.grey)),
                  Chip(
                    avatar: const Icon(Icons.verified, size: 16,
                        color: Colors.white),
                    label: Text('${confidence.toStringAsFixed(1)}% match'),
                    backgroundColor: confidence > 70
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                    labelStyle: const TextStyle(
                        color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                product.name,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text('SKU: ${product.sku} | Stock: ${product.stockQuantity}'),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '\$${price.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.indigo),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                    ),
                    onPressed: () {
                      widget.onAddToBasket(product);
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.add_shopping_cart),
                    label: const Text('Add to Total'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_cameras.isEmpty) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, size: 64, color: Colors.grey),
              SizedBox(height: 12),
              Text('No camera detected on this device.',
                  style: TextStyle(color: Colors.grey)),
              SizedBox(height: 4),
              Text('Use a physical Android/iOS device for visual search.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Store Visual Search'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || _controller == null) {
            return const Center(
                child: Text('Camera init failed.',
                    style: TextStyle(color: Colors.white)));
          }
          return Stack(
            children: [
              // Live camera feed
              Positioned.fill(child: CameraPreview(_controller!)),
              // Targeting frame
              Center(
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _isSearching ? Colors.amber : Colors.white,
                      width: 3.0,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              // Instruction banner
              Positioned(
                top: 20, left: 0, right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Align unlabelled item in target box',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'First search may take 5–15 s on CPU',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Snap button
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 30),
                  child: FloatingActionButton.large(
                    onPressed: _isSearching ? null : _captureAndSearch,
                    backgroundColor:
                        _isSearching ? Colors.grey : Colors.indigo,
                    child: _isSearching
                        ? const CircularProgressIndicator(
                            color: Colors.white)
                        : const Icon(Icons.camera_alt,
                            size: 36, color: Colors.white),
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
