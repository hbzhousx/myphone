/// 百度坐标（BD-09）与标准坐标（WGS-84）互转。
/// 百度地图瓦片用 BD-09 加密坐标，geolocator 返回 WGS-84。
/// flutter_map 用标准墨卡托 CRS，但把经纬度转 BD-09 后按标准瓦片号请求
/// 百度瓦片（百度按 BD-09 解释瓦片坐标）→ 显示正确；发送时转回 WGS-84。
library;

import 'dart:math' as math;

const double _xPi = math.pi * 3000.0 / 180.0;

/// WGS-84 → GCJ-02（火星坐标）。
(double, double) _wgs84ToGcj02(double lng, double lat) {
  if (_outOfChina(lng, lat)) return (lng, lat);
  double dLat = _transformLat(lng - 105.0, lat - 35.0);
  double dLng = _transformLng(lng - 105.0, lat - 35.0);
  final radLat = lat / 180.0 * math.pi;
  double magic = math.sin(radLat);
  magic = 1 - 0.00669342162296594323 * magic * magic;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) /
      ((6378245.0 * (1 - 0.00669342162296594323)) / (magic * sqrtMagic) *
          math.pi);
  dLng = (dLng * 180.0) / (6378245.0 / sqrtMagic * math.cos(radLat) * math.pi);
  return (lng + dLng, lat + dLat);
}

/// GCJ-02 → BD-09。
(double, double) _gcj02ToBd09(double lng, double lat) {
  final z = math.sqrt(lng * lng + lat * lat) +
      0.00002 * math.sin(lat * _xPi);
  final theta = math.atan2(lat, lng) + 0.000003 * math.cos(lng * _xPi);
  return (z * math.cos(theta) + 0.0065, z * math.sin(theta) + 0.006);
}

/// WGS-84 → BD-09（地图显示用：flutter_map 中心/选点用 BD-09）。
(double lng, double lat) wgs84ToBd09(double lng, double lat) {
  final gcj = _wgs84ToGcj02(lng, lat);
  return _gcj02ToBd09(gcj.$1, gcj.$2);
}

/// BD-09 → GCJ-02。
(double, double) _bd09ToGcj02(double lng, double lat) {
  final x = lng - 0.0065;
  final y = lat - 0.006;
  final z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * _xPi);
  final theta = math.atan2(y, x) - 0.000003 * math.cos(x * _xPi);
  return (z * math.cos(theta), z * math.sin(theta));
}

/// GCJ-02 → WGS-84。
(double, double) _gcj02ToWgs84(double lng, double lat) {
  final g = _wgs84ToGcj02(lng, lat);
  return (lng * 2 - g.$1, lat * 2 - g.$2);
}

/// BD-09 → WGS-84（发送给接收方用，geo: 系统地图准）。
(double lng, double lat) bd09ToWgs84(double lng, double lat) {
  final gcj = _bd09ToGcj02(lng, lat);
  return _gcj02ToWgs84(gcj.$1, gcj.$2);
}

/// WGS-84 → GCJ-02（火星坐标，高德瓦片显示用）。
(double lng, double lat) wgs84ToGcj02(double lng, double lat) {
  return _wgs84ToGcj02(lng, lat);
}

/// GCJ-02 → BD-09（百度地图用）。
(double lng, double lat) gcj02ToBd09(double lng, double lat) {
  return _gcj02ToBd09(lng, lat);
}

/// GCJ-02 → WGS-84（高德选点发送用，转回标准坐标）。
(double lng, double lat) gcj02ToWgs84(double lng, double lat) {
  return _gcj02ToWgs84(lng, lat);
}

bool _outOfChina(double lng, double lat) {
  return !(lng > 73.66 && lng < 135.05 && lat > 3.86 && lat < 53.55);
}

double _transformLat(double x, double y) {
  double ret = -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
      20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * math.pi) +
      40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) +
      320 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLng(double x, double y) {
  double ret = 300.0 +
      x +
      2.0 * y +
      0.1 * x * x +
      0.1 * x * y +
      0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
      20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * math.pi) +
      40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) +
      300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}
