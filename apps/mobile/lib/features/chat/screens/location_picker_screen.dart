/// 位置选点页（微信式）：地图显示当前位置，中央十字准星选点，确认后返回坐标。
/// 用 flutter_map + OpenStreetMap 免费瓦片，无需 key。
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/utils/bd_coords.dart';

/// 选点结果：坐标 + 地址文本（简化：坐标字符串，可后续接反向地理编码）。
class LocationPickResult {
  final double latitude;
  final double longitude;
  const LocationPickResult({required this.latitude, required this.longitude});
}

/// 打开选点页，返回用户选中的坐标；取消返回 null。
/// [initial] 可选：初始位置（否则取当前定位）。
Future<LocationPickResult?> showLocationPicker(
  BuildContext context, {
  Position? initial,
}) {
  return Navigator.of(context).push<LocationPickResult>(
    MaterialPageRoute(
      builder: (_) => LocationPickerScreen(initial: initial),
    ),
  );
}

class LocationPickerScreen extends StatefulWidget {
  final Position? initial;
  const LocationPickerScreen({super.key, this.initial});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController _mapController = MapController();
  LatLng? _center; // 地图中心 = 选点（十字准星）
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // ★高德瓦片用 GCJ-02(火星)坐标：flutter_map 中心/选点用 GCJ-02 经纬度
    //   （高德瓦片网格=标准墨卡托，按 GCJ-02 解释瓦片坐标 → 正确显示）。
    //   geolocator 返回 WGS-84，需转 GCJ-02。选点返回时转回 WGS-84 发送。
    LatLng wgsToCenter(double lat, double lng) {
      final gcj = wgs84ToGcj02(lng, lat);
      return LatLng(gcj.$2, gcj.$1);
    }

    if (widget.initial != null) {
      setState(() {
        _center = wgsToCenter(widget.initial!.latitude, widget.initial!.longitude);
        _loading = false;
      });
      return;
    }
    try {
      // 取当前定位（高精度 + 超时；失败用 lastKnown 兜底）。
      Position pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          forceAndroidLocationManager: true,
          timeLimit: const Duration(seconds: 10),
        );
      } catch (_) {
        final last = await Geolocator.getLastKnownPosition();
        if (last == null) {
          setState(() => _err = '获取当前位置失败，请手动拖动地图选点');
          _center = wgsToCenter(30.5728, 114.2864); // 默认武汉，用户可拖
          _loading = false;
          return;
        }
        pos = last;
      }
      if (!mounted) return;
      setState(() {
        _center = wgsToCenter(pos.latitude, pos.longitude);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '获取当前位置失败，请手动拖动地图选点';
        _center = wgsToCenter(30.5728, 114.2864);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = _center;
    return Scaffold(
      appBar: AppBar(
        title: const Text('发送位置'),
        actions: [
          if (center != null)
            TextButton(
              onPressed: () {
                // ★直接发 GCJ-02（高德选点/瓦片都是 GCJ-02）：接收端高德 URI 直接用
                //   GCJ-02(dev=0) 显示准。不转 WGS-84（避免两次转换累积误差）。
                Navigator.of(context).pop(LocationPickResult(
                  latitude: center.latitude,
                  longitude: center.longitude,
                ));
              },
              child: const Text('发送'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                if (center != null)
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: center,
                      initialZoom: 16,
                      // 地图中心即选点（红准星指向）：任何位置变化都更新。
                      // ★不能依赖 hasGesture（拖动/惯性可能 false）——无条件更新。
                      onPositionChanged: (camera, _) {
                        if (_center != camera.center) {
                          setState(() => _center = camera.center);
                        }
                      },
                    ),
                    children: [
                      TileLayer(
                        // 高德瓦片：国内细节丰富 + 网格=标准墨卡托（验证过有效图）。
                        // ★坐标转 GCJ-02 显示（中心/选点都是 GCJ-02），发送转回 WGS-84。
                        urlTemplate:
                            'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                        subdomains: const ['1', '2', '3', '4'],
                        userAgentPackageName: 'com.myphone.app',
                        tileProvider: NetworkTileProvider(),
                      ),
                      // ★不叠加 Marker 蓝标：flutter_map 用标准 CRS(WGS-84)渲染
                      //   Marker，而地图坐标是 GCJ-02，蓝标会偏移造成困惑。
                      //   红准星(固定屏幕中心)对准高德地图即真实位置，足够。
                    ],
                  ),
                // 中央十字准星（选点指示）。
                IgnorePointer(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.location_on,
                          color: Colors.red,
                          size: 36,
                        ),
                        // 显示当前选点坐标（GCJ-02），拖动时实时更新，
                        // 用于确认红准星对准位置与坐标一致。
                        if (_center != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            color: Colors.black54,
                            child: Text(
                              '${_center!.latitude.toStringAsFixed(5)}, '
                              '${_center!.longitude.toStringAsFixed(5)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_err != null)
                  Positioned(
                    top: 10,
                    left: 0,
                    right: 0,
                    child: Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _err!,
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
