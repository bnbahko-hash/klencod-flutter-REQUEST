// ============================================================================
// REQUEST - TikTok Account Manager (Official APIs Only)
// OAuth 2.0 + PKCE | Display API | Content Posting API
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

// ============================================================================
// 1. CONFIGURATION
// ============================================================================

class AppConfig {
  static const String clientKey = 'YOUR_TIKTOK_CLIENT_KEY';
  static const String redirectUri = 'request://callback';
  static const String callbackScheme = 'request';
  static const String backendBaseUrl = 'https://your-backend.example.com';

  static const List<String> scopes = [
    'user.info.basic',
    'user.info.profile',
    'user.info.stats',
    'video.list',
    'video.upload',
    'video.publish',
  ];

  static const String tiktokAuthUrl = 'https://www.tiktok.com/v2/auth/authorize/';
  static const String tiktokApiBase = 'https://open.tiktokapis.com/v2';

  static const int maxChunkSize = 64 * 1024 * 1024;
  static const int maxVideoSize = 128 * 1024 * 1024;
  static const int maxVideosPerPage = 20;
}

// ============================================================================
// 2. MODELS
// ============================================================================

class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final String openId;
  final int expiresIn;
  final DateTime issuedAt;

  AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.openId,
    required this.expiresIn,
    DateTime? issuedAt,
  }) : issuedAt = issuedAt ?? DateTime.now();

  bool get isExpired =>
      DateTime.now().isAfter(issuedAt.add(Duration(seconds: expiresIn - 300)));

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'open_id': openId,
        'expires_in': expiresIn,
        'issued_at': issuedAt.toIso8601String(),
      };

  factory AuthTokens.fromJson(Map<String, dynamic> j) => AuthTokens(
        accessToken: j['access_token'] ?? '',
        refreshToken: j['refresh_token'] ?? '',
        openId: j['open_id'] ?? '',
        expiresIn: j['expires_in'] ?? 86400,
        issuedAt: j['issued_at'] != null
            ? DateTime.parse(j['issued_at'])
            : DateTime.now(),
      );
}

class TikTokUser {
  final String openId;
  final String unionId;
  final String displayName;
  final String avatarUrl;
  final String bioDescription;
  final bool isVerified;
  final String profileDeepLink;
  final int followerCount;
  final int followingCount;
  final int likesCount;
  final int videoCount;

  TikTokUser({
    required this.openId,
    required this.unionId,
    required this.displayName,
    required this.avatarUrl,
    required this.bioDescription,
    required this.isVerified,
    required this.profileDeepLink,
    required this.followerCount,
    required this.followingCount,
    required this.likesCount,
    required this.videoCount,
  });

  factory TikTokUser.fromJson(Map<String, dynamic> j) => TikTokUser(
        openId: j['open_id'] ?? '',
        unionId: j['union_id'] ?? '',
        displayName: j['display_name'] ?? 'TikTok User',
        avatarUrl: j['avatar_url'] ?? '',
        bioDescription: j['bio_description'] ?? '',
        isVerified: j['is_verified'] ?? false,
        profileDeepLink: j['profile_deep_link'] ?? '',
        followerCount: j['follower_count'] ?? 0,
        followingCount: j['following_count'] ?? 0,
        likesCount: j['likes_count'] ?? 0,
        videoCount: j['video_count'] ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'open_id': openId,
        'union_id': unionId,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'bio_description': bioDescription,
        'is_verified': isVerified,
        'profile_deep_link': profileDeepLink,
        'follower_count': followerCount,
        'following_count': followingCount,
        'likes_count': likesCount,
        'video_count': videoCount,
      };
}

class TikTokVideo {
  final String id;
  final String title;
  final String description;
  final int duration;
  final String coverUrl;
  final String shareUrl;
  final DateTime createTime;
  final int viewCount;
  final int likeCount;
  final int commentCount;
  final int shareCount;

  TikTokVideo({
    required this.id,
    required this.title,
    required this.description,
    required this.duration,
    required this.coverUrl,
    required this.shareUrl,
    required this.createTime,
    required this.viewCount,
    required this.likeCount,
    required this.commentCount,
    required this.shareCount,
  });

  factory TikTokVideo.fromJson(Map<String, dynamic> j) => TikTokVideo(
        id: j['id'] ?? '',
        title: j['title'] ?? '',
        description: j['video_description'] ?? '',
        duration: j['duration'] ?? 0,
        coverUrl: j['cover_image_url'] ?? '',
        shareUrl: j['share_url'] ?? '',
        createTime: DateTime.fromMillisecondsSinceEpoch(
            (j['create_time'] ?? 0) * 1000),
        viewCount: j['view_count'] ?? 0,
        likeCount: j['like_count'] ?? 0,
        commentCount: j['comment_count'] ?? 0,
        shareCount: j['share_count'] ?? 0,
      );
}

// ============================================================================
// 3. SECURE STORAGE
// ============================================================================

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _kTokens = 'request_auth_tokens';
  static const _kUser = 'request_cached_user';

  Future<void> saveTokens(AuthTokens t) =>
      _storage.write(key: _kTokens, value: jsonEncode(t.toJson()));

  Future<AuthTokens?> loadTokens() async {
    final raw = await _storage.read(key: _kTokens);
    if (raw == null) return null;
    return AuthTokens.fromJson(jsonDecode(raw));
  }

  Future<void> saveUser(TikTokUser u) =>
      _storage.write(key: _kUser, value: jsonEncode(u.toJson()));

  Future<TikTokUser?> loadUser() async {
    final raw = await _storage.read(key: _kUser);
    if (raw == null) return null;
    return TikTokUser.fromJson(jsonDecode(raw));
  }

  Future<void> clear() async {
    await _storage.delete(key: _kTokens);
    await _storage.delete(key: _kUser);
  }
}

// ============================================================================
// 4. AUTH SERVICE
// ============================================================================

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class AuthService {
  final SecureStorageService _storage;
  final Dio _dio;
  AuthTokens? _tokens;

  AuthService(this._storage)
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
        ));

  AuthTokens? get tokens => _tokens;

  (String, String) _generatePKCE() {
    final rand = Random.secure();
    final verifier = base64Url
        .encode(List.generate(32, (_) => rand.nextInt(256)))
        .replaceAll('=', '');
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    return (verifier, challenge);
  }

  Future<AuthTokens> login() async {
    final (verifier, challenge) = _generatePKCE();
    final state = _randomString(16);

    final authUri = Uri.parse(AppConfig.tiktokAuthUrl).replace(
      queryParameters: {
        'client_key': AppConfig.clientKey,
        'scope': AppConfig.scopes.join(','),
        'response_type': 'code',
        'redirect_uri': AppConfig.redirectUri,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );

    final String result;
    try {
      result = await FlutterWebAuth2.authenticate(
        url: authUri.toString(),
        callbackUrlScheme: AppConfig.callbackScheme,
      );
    } on PlatformException catch (e) {
      throw AuthException('Authorization cancelled: ${e.message}');
    }

    final cb = Uri.parse(result);
    if (cb.queryParameters['error'] != null) {
      throw AuthException('Denied: ${cb.queryParameters['error']}');
    }
    if (cb.queryParameters['state'] != state) {
      throw AuthException('State mismatch');
    }
    final code = cb.queryParameters['code'];
    if (code == null) throw AuthException('No code received');

    return _exchangeCode(code, verifier);
  }

  Future<AuthTokens> _exchangeCode(String code, String verifier) async {
    final resp = await _dio.post(
      '${AppConfig.backendBaseUrl}/auth/exchange',
      data: {
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': AppConfig.redirectUri,
      },
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    if (resp.statusCode != 200) {
      throw AuthException('Exchange failed: ${resp.statusCode} ${resp.data}');
    }
    _tokens = AuthTokens.fromJson(resp.data as Map<String, dynamic>);
    await _storage.saveTokens(_tokens!);
    return _tokens!;
  }

  Future<void> refreshToken() async {
    if (_tokens == null) throw AuthException('No session');
    final resp = await _dio.post(
      '${AppConfig.backendBaseUrl}/auth/refresh',
      data: {'refresh_token': _tokens!.refreshToken},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    if (resp.statusCode != 200) {
      throw AuthException('Refresh failed: ${resp.statusCode}');
    }
    _tokens = AuthTokens.fromJson(resp.data as Map<String, dynamic>);
    await _storage.saveTokens(_tokens!);
  }

  Future<void> revokeToken() async {
    if (_tokens == null) return;
    try {
      await _dio.post(
        '${AppConfig.backendBaseUrl}/auth/revoke',
        data: {'access_token': _tokens!.accessToken},
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
    } catch (_) {}
  }

  Future<void> restoreSession() async {
    _tokens = await _storage.loadTokens();
  }

  Future<void> logout() async {
    await revokeToken();
    _tokens = null;
    await _storage.clear();
  }

  String _randomString(int len) {
    final rand = Random.secure();
    return List.generate(len, (_) => rand.nextInt(36))
        .map((n) => n.toRadixString(36))
        .join();
  }
}

// ============================================================================
// 5. TIKTOK API SERVICE (Dio + retry + auto-refresh)
// ============================================================================

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  ApiException(this.message, [this.statusCode]);
  @override
  String toString() => message;
}

class TikTokApiService {
  final AuthService _auth;
  late final Dio _dio;

  TikTokApiService(this._auth) {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.tiktokApiBase,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ));

    _dio.interceptors.add(RetryInterceptor(
      dio: _dio,
      retries: 3,
      retryDelays: const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 3),
      ],
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (_auth.tokens == null) {
          return handler.reject(DioException(
            requestOptions: options,
            error: 'Not logged in',
          ));
        }
        if (_auth.tokens!.isExpired) {
          await _auth.refreshToken();
        }
        options.headers['Authorization'] =
            'Bearer ${_auth.tokens!.accessToken}';
        options.headers['Content-Type'] = 'application/json';
        return handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode == 401 && _auth.tokens != null) {
          try {
            await _auth.refreshToken();
            final opts = error.requestOptions;
            opts.headers['Authorization'] =
                'Bearer ${_auth.tokens!.accessToken}';
            final clone = await _dio.fetch(opts);
            return handler.resolve(clone);
          } catch (_) {
            return handler.next(error);
          }
        }
        return handler.next(error);
      },
    ));
  }

  static const _userFields = [
    'open_id', 'union_id', 'avatar_url', 'display_name', 'bio_description',
    'profile_deep_link', 'is_verified', 'follower_count', 'following_count',
    'likes_count', 'video_count',
  ];

  Future<TikTokUser> getUserInfo() async {
    final resp = await _dio.get(
      '/user/info/',
      queryParameters: {'fields': _userFields.join(',')},
    );
    _throwIfBad(resp);
    return TikTokUser.fromJson(
        resp.data['data']['user'] as Map<String, dynamic>);
  }

  Future<List<TikTokVideo>> getVideos({
    int maxCount = AppConfig.maxVideosPerPage,
    int cursor = 0,
  }) async {
    final resp = await _dio.post(
      '/video/list/',
      data: {
        'max_count': min(maxCount, AppConfig.maxVideosPerPage),
        'cursor': cursor,
        'fields': [
          'id', 'title', 'video_description', 'duration', 'cover_image_url',
          'share_url', 'create_time', 'view_count', 'like_count',
          'comment_count', 'share_count',
        ],
      },
    );
    _throwIfBad(resp);
    final list = (resp.data['data']?['videos'] as List?) ?? [];
    return list.map((e) => TikTokVideo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<String> uploadVideo({
    required File videoFile,
    required String title,
    String description = '',
    String privacyLevel = 'SELF_ONLY',
    bool disableComment = false,
    bool disableDuet = false,
    bool disableStitch = false,
    void Function(double progress)? onProgress,
  }) async {
    final fileSize = await videoFile.length();
    if (fileSize > AppConfig.maxVideoSize) {
      throw ApiException('Video too large');
    }

    final int chunkSize;
    final int totalChunks;
    if (fileSize <= AppConfig.maxChunkSize) {
      chunkSize = fileSize;
      totalChunks = 1;
    } else {
      chunkSize = AppConfig.maxChunkSize;
      totalChunks = fileSize ~/ chunkSize;
    }

    final initResp = await _dio.post(
      '/post/publish/video/init/',
      data: {
        'post_info': {
          'title': title,
          'description': description,
          'privacy_level': privacyLevel,
          'disable_comment': disableComment,
          'disable_duet': disableDuet,
          'disable_stitch': disableStitch,
        },
        'source_info': {
          'source': 'FILE_UPLOAD',
          'video_size': fileSize,
          'chunk_size': chunkSize,
          'total_chunk_count': totalChunks,
        },
      },
    );
    _throwIfBad(initResp);

    final uploadUrl = initResp.data['data']['upload_url'] as String;
    final publishId = initResp.data['data']['publish_id'] as String;

    final raf = await videoFile.open();
    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = min(start + chunkSize, fileSize) - 1;
        final length = end - start + 1;

        await raf.setPosition(start);
        final Uint8List buffer = await raf.read(length);

        final putResp = await Dio().put(
          uploadUrl,
          data: Stream.fromIterable([buffer]),
          options: Options(
            headers: {
              'Content-Range': 'bytes $start-$end/$fileSize',
              'Content-Type': 'video/mp4',
              'Content-Length': length.toString(),
            },
          ),
        );

        if (putResp.statusCode == null ||
            putResp.statusCode! < 200 ||
            putResp.statusCode! >= 300) {
          throw ApiException(
              'Chunk ${i + 1} upload failed: ${putResp.statusCode}');
        }
        onProgress?.call((i + 1) / totalChunks);
      }
    } finally {
      await raf.close();
    }

    return publishId;
  }

  Future<Map<String, dynamic>> getPublishStatus(String publishId) async {
    final resp = await _dio.post(
      '/post/publish/status/fetch/',
      data: {'publish_id': publishId},
    );
    _throwIfBad(resp);
    return resp.data['data'] as Map<String, dynamic>;
  }

  void _throwIfBad(Response resp) {
    if (resp.statusCode != null &&
        (resp.statusCode! < 200 || resp.statusCode! >= 300)) {
      throw ApiException(
          'TikTok API error ${resp.statusCode}: ${resp.data}',
          resp.statusCode);
    }
    final data = resp.data;
    if (data is Map<String, dynamic>) {
      final errCode = data['error']?['code'];
      if (errCode != null && errCode != 'ok') {
        throw ApiException(
            'TikTok error: ${data['error']['message'] ?? errCode}');
      }
    }
  }
}

// ============================================================================
// 6. APP STATE
// ============================================================================

class AppState extends ChangeNotifier {
  final SecureStorageService storage;
  late final AuthService _auth;
  late final TikTokApiService _api;

  AuthTokens? tokens;
  TikTokUser? user;
  List<TikTokVideo> videos = [];
  bool isLoadingUser = false;
  bool isLoadingVideos = false;
  bool isLoggedIn = false;
  String? lastError;
  bool hasMoreVideos = true;
  int _nextCursor = 0;

  AppState() : storage = SecureStorageService() {
    _auth = AuthService(storage);
    _api = TikTokApiService(_auth);
  }

  AuthService get authService => _auth;
  TikTokApiService get apiService => _api;

  Future<void> bootstrap() async {
    await _auth.restoreSession();
    tokens = _auth.tokens;
    isLoggedIn = tokens != null;
    if (isLoggedIn) {
      user = await storage.loadUser();
      notifyListeners();
      unawaited(refreshAll());
    }
  }

  Future<void> login() async {
    isLoadingUser = true;
    lastError = null;
    notifyListeners();
    try {
      tokens = await _auth.login();
      isLoggedIn = true;
      user = await _api.getUserInfo();
      await storage.saveUser(user!);
      notifyListeners();
      await loadVideos(reset: true);
    } catch (e) {
      lastError = e.toString();
      isLoggedIn = false;
      tokens = null;
    } finally {
      isLoadingUser = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _auth.logout();
    tokens = null;
    user = null;
    videos = [];
    _nextCursor = 0;
    hasMoreVideos = true;
    isLoggedIn = false;
    notifyListeners();
  }

  Future<void> refreshAll() async {
    await Future.wait([loadUser(), loadVideos(reset: true)]);
  }

  Future<void> loadUser() async {
    if (!isLoggedIn) return;
    isLoadingUser = true;
    notifyListeners();
    try {
      user = await _api.getUserInfo();
      await storage.saveUser(user!);
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      isLoadingUser = false;
      notifyListeners();
    }
  }

  Future<void> loadVideos({bool reset = false}) async {
    if (!isLoggedIn) return;
    if (reset) {
      _nextCursor = 0;
      hasMoreVideos = true;
      videos = [];
    }
    if (!hasMoreVideos) return;
    isLoadingVideos = true;
    notifyListeners();
    try {
      final page = await _api.getVideos(cursor: _nextCursor);
      if (page.isEmpty) {
        hasMoreVideos = false;
      } else {
        videos = [...videos, ...page];
        _nextCursor += page.length;
        if (page.length < AppConfig.maxVideosPerPage) hasMoreVideos = false;
      }
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      isLoadingVideos = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreVideos() async {
    if (isLoadingVideos || !hasMoreVideos) return;
    await loadVideos();
  }
}

// ============================================================================
// 7. MAIN
// ============================================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..bootstrap(),
      child: const RequestApp(),
    ),
  );
}

class RequestApp extends StatelessWidget {
  const RequestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'REQUEST',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const _RootRouter(),
    );
  }

  ThemeData _buildTheme() {
    const bg = Color(0xFF0F0F0F);
    const surface = Color(0xFF1C1C1E);
    const pink = Color(0xFFFE2C55);
    const cyan = Color(0xFF25F4EE);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: pink,
        secondary: cyan,
        surface: surface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: true,
      ),
      // FIX: في Flutter 3.47+ الخصيصة تقبل CardThemeData
      cardTheme: CardThemeData(
        color: surface,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: pink,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _RootRouter extends StatelessWidget {
  const _RootRouter();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return state.isLoggedIn ? const HomeScreen() : const LoginScreen();
  }
}

// ============================================================================
// 8. LOGIN
// ============================================================================

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              _logo(),
              const SizedBox(height: 32),
              const Text('REQUEST',
                  style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4)),
              const SizedBox(height: 8),
              const Text('TikTok Account Manager',
                  style: TextStyle(fontSize: 16, color: Colors.white54)),
              const SizedBox(height: 12),
              const Text(
                'Full control over your TikTok account\n'
                'Profile, stats, content management, and uploads',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, height: 1.5),
              ),
              const Spacer(),
              if (state.lastError != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(state.lastError!,
                      style: const TextStyle(color: Colors.redAccent),
                      textAlign: TextAlign.center),
                ),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed:
                      state.isLoadingUser ? null : () => state.login(),
                  icon: state.isLoadingUser
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.login),
                  label: Text(state.isLoadingUser
                      ? 'Connecting...'
                      : 'Login with TikTok'),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Official TikTok OAuth 2.0 + PKCE.\n'
                'Password never stored. Revoke access anytime.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logo() => Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF25F4EE), Color(0xFFFE2C55)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFE2C55).withOpacity(0.3),
              blurRadius: 30,
              spreadRadius: 5,
            ),
          ],
        ),
        child: const Icon(Icons.music_note, size: 64, color: Colors.white),
      );
}

// ============================================================================
// 9. HOME
// ============================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    const pages = [
      ProfileTab(),
      VideosTab(),
      UploadTab(),
      AnalyticsTab(),
      SettingsTab(),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: const Color(0xFF1C1C1E),
        indicatorColor: const Color(0xFFFE2C55).withOpacity(0.25),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile'),
          NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              selectedIcon: Icon(Icons.video_library),
              label: 'Videos'),
          NavigationDestination(
              icon: Icon(Icons.cloud_upload_outlined),
              selectedIcon: Icon(Icons.cloud_upload),
              label: 'Upload'),
          NavigationDestination(
              icon: Icon(Icons.analytics_outlined),
              selectedIcon: Icon(Icons.analytics),
              label: 'Analytics'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}

// ============================================================================
// 10. PROFILE
// ============================================================================

class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.user;
    return RefreshIndicator(
      onRefresh: state.refreshAll,
      color: const Color(0xFFFE2C55),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Text('My Profile',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (state.isLoadingUser)
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 20),
          if (user == null)
            const _EmptyState(message: 'Loading account data...')
          else
            _ProfileCard(user: user),
          const SizedBox(height: 16),
          if (user != null) _QuickStats(user: user),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final TikTokUser user;
  const _ProfileCard({required this.user});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: Colors.grey.shade800,
                  backgroundImage: user.avatarUrl.isNotEmpty
                      ? NetworkImage(user.avatarUrl)
                      : null,
                  child: user.avatarUrl.isEmpty
                      ? const Icon(Icons.person, size: 40)
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(user.displayName,
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis),
                          ),
                          if (user.isVerified)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(Icons.verified,
                                  color: Color(0xFF25F4EE), size: 20),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '@${user.openId.substring(0, min(12, user.openId.length))}',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (user.bioDescription.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(user.bioDescription,
                  style: const TextStyle(
                      color: Colors.white70, height: 1.5)),
            ],
            if (user.profileDeepLink.isNotEmpty) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () async {
                  final uri = Uri.parse(user.profileDeepLink);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open in TikTok'),
              ),
            ],
            const Divider(height: 32, color: Colors.white12),
            const _InfoRow(label: 'Account ID', value: ''),
            SelectableText(user.openId,
                style:
                    const TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 8),
            _InfoRow(label: 'Union ID', value: user.unionId),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value,
                style:
                    const TextStyle(fontSize: 13, color: Colors.white70),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _QuickStats extends StatelessWidget {
  final TikTokUser user;
  const _QuickStats({required this.user});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child:
                _StatCard(label: 'Followers', value: user.followerCount)),
        const SizedBox(width: 8),
        Expanded(
            child: _StatCard(
                label: 'Following', value: user.followingCount)),
        const SizedBox(width: 8),
        Expanded(
            child: _StatCard(label: 'Likes', value: user.likesCount)),
        const SizedBox(width: 8),
        Expanded(
            child: _StatCard(label: 'Videos', value: user.videoCount)),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final int value;
  const _StatCard({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Text(_formatNumber(value),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(label,
              style:
                  const TextStyle(fontSize: 11, color: Colors.white54)),
        ],
      ),
    );
  }
}

String _formatNumber(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

// ============================================================================
// 11. VIDEOS
// ============================================================================

class VideosTab extends StatefulWidget {
  const VideosTab({super.key});
  @override
  State<VideosTab> createState() => _VideosTabState();
}

class _VideosTabState extends State<VideosTab> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  void _onScroll() {
    if (_controller.position.pixels >=
        _controller.position.maxScrollExtent - 300) {
      context.read<AppState>().loadMoreVideos();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Text('My Videos',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Chip(
                label: Text('${state.videos.length}'),
                backgroundColor: const Color(0xFF1C1C1E),
              ),
              const Spacer(),
              IconButton(
                onPressed: state.isLoadingVideos
                    ? null
                    : () => state.loadVideos(reset: true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => state.loadVideos(reset: true),
            color: const Color(0xFFFE2C55),
            child: state.isLoadingVideos && state.videos.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : state.videos.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 100),
                        _EmptyState(
                            message:
                                'No videos found, or video.list scope not granted'),
                      ])
                    : ListView.separated(
                        controller: _controller,
                        padding: const EdgeInsets.all(16),
                        itemCount: state.videos.length +
                            (state.hasMoreVideos ? 1 : 0),
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 12),
                        itemBuilder: (_, i) {
                          if (i == state.videos.length) {
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            );
                          }
                          return _VideoCard(video: state.videos[i]);
                        },
                      ),
          ),
        ),
      ],
    );
  }
}

class _VideoCard extends StatelessWidget {
  final TikTokVideo video;
  const _VideoCard({required this.video});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 72,
                height: 96,
                child: video.coverUrl.isNotEmpty
                    ? Image.network(video.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder())
                    : _placeholder(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title.isNotEmpty ? video.title : 'Untitled',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (video.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(video.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _mini(Icons.visibility,
                          _formatNumber(video.viewCount)),
                      const SizedBox(width: 12),
                      _mini(Icons.favorite,
                          _formatNumber(video.likeCount)),
                      const SizedBox(width: 12),
                      _mini(Icons.comment,
                          _formatNumber(video.commentCount)),
                      const SizedBox(width: 12),
                      _mini(Icons.share, _formatNumber(video.shareCount)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat('yyyy-MM-dd HH:mm')
                        .format(video.createTime),
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
        color: Colors.black26,
        child: const Icon(Icons.videocam, color: Colors.white24),
      );

  Widget _mini(IconData icon, String val) => Row(
        children: [
          Icon(icon, size: 14, color: Colors.white54),
          const SizedBox(width: 3),
          Text(val,
              style: const TextStyle(
                  fontSize: 11, color: Colors.white70)),
        ],
      );
}

// ============================================================================
// 12. UPLOAD
// ============================================================================

class UploadTab extends StatefulWidget {
  const UploadTab({super.key});
  @override
  State<UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<UploadTab> {
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  String _privacy = 'SELF_ONLY';
  bool _disableComment = false;
  bool _disableDuet = false;
  bool _disableStitch = false;
  File? _videoFile;
  int _fileSize = 0;
  double _progress = 0;
  bool _isUploading = false;
  String? _publishId;
  String? _statusMessage;

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.gallery);
    if (picked != null) {
      final f = File(picked.path);
      final size = await f.length();
      setState(() {
        _videoFile = f;
        _fileSize = size;
        _statusMessage = null;
      });
    }
  }

  Future<void> _upload() async {
    final state = context.read<AppState>();
    if (_videoFile == null) return _snack('Select a video first');
    if (_titleController.text.trim().isEmpty) {
      return _snack('Enter a title');
    }
    if (_fileSize > AppConfig.maxVideoSize) {
      return _snack('Video exceeds max size');
    }

    setState(() {
      _isUploading = true;
      _progress = 0;
      _publishId = null;
      _statusMessage = 'Initializing upload...';
    });

    try {
      final publishId = await state.apiService.uploadVideo(
        videoFile: _videoFile!,
        title: _titleController.text.trim(),
        description: _descController.text.trim(),
        privacyLevel: _privacy,
        disableComment: _disableComment,
        disableDuet: _disableDuet,
        disableStitch: _disableStitch,
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progress = p;
              _statusMessage =
                  'Uploading: ${(p * 100).toStringAsFixed(0)}%';
            });
          }
        },
      );

      setState(() {
        _publishId = publishId;
        _statusMessage = 'Uploaded, publishing...';
      });

      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(seconds: 3));
        final status =
            await state.apiService.getPublishStatus(publishId);
        final st = status['status'] as String? ?? '';
        if (mounted) setState(() => _statusMessage = 'Status: $st');
        if (st == 'PUBLISH_COMPLETE' || st == 'FAILED') break;
      }

      if (mounted) {
        setState(() => _statusMessage = 'Completed successfully ✅');
        _snack('Published successfully');
        await state.loadVideos(reset: true);
        await state.loadUser();
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed: $e');
      _snack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Upload New Video',
            style:
                TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: _isUploading ? null : _pickVideo,
          child: Container(
            height: 180,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: Center(
              child: _videoFile == null
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_upload_outlined,
                            size: 48, color: Colors.white54),
                        SizedBox(height: 8),
                        Text('Tap to select video',
                            style:
                                TextStyle(color: Colors.white54)),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle,
                            size: 48, color: Color(0xFF25F4EE)),
                        const SizedBox(height: 8),
                        Text(
                          _videoFile!.path
                              .split(Platform.pathSeparator)
                              .last,
                          style: const TextStyle(
                              color: Colors.white70),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${(_fileSize / (1024 * 1024)).toStringAsFixed(2)} MB',
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _titleController,
          decoration: const InputDecoration(
              labelText: 'Title', hintText: 'Video title'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _descController,
          maxLines: 3,
          decoration: const InputDecoration(
              labelText: 'Description (optional)',
              hintText: 'Video description'),
        ),
        const SizedBox(height: 16),
        const Text('Privacy',
            style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'SELF_ONLY', label: Text('Only me')),
            ButtonSegment(
                value: 'MUTUAL_FOLLOW_FRIENDS',
                label: Text('Friends')),
            ButtonSegment(
                value: 'PUBLIC_TO_EVERYONE',
                label: Text('Public')),
          ],
          selected: {_privacy},
          onSelectionChanged: (s) =>
              setState(() => _privacy = s.first),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          title: const Text('Disable comments'),
          value: _disableComment,
          onChanged: (v) => setState(() => _disableComment = v),
        ),
        SwitchListTile(
          title: const Text('Disable Duet'),
          value: _disableDuet,
          onChanged: (v) => setState(() => _disableDuet = v),
        ),
        SwitchListTile(
          title: const Text('Disable Stitch'),
          value: _disableStitch,
          onChanged: (v) => setState(() => _disableStitch = v),
        ),
        const SizedBox(height: 16),
        if (_isUploading) ...[
          LinearProgressIndicator(
            value: _progress == 0 ? null : _progress,
            backgroundColor: Colors.white12,
            color: const Color(0xFFFE2C55),
          ),
          const SizedBox(height: 8),
          if (_statusMessage != null)
            Text(_statusMessage!,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
        ],
        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _isUploading ? null : _upload,
            icon: _isUploading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.upload),
            label: Text(
                _isUploading ? 'Uploading...' : 'Upload to TikTok'),
          ),
        ),
        if (_publishId != null) ...[
          const SizedBox(height: 12),
          Text('Publish ID: $_publishId',
              style: const TextStyle(
                  color: Colors.white38, fontSize: 11)),
        ],
      ],
    );
  }
}

// ============================================================================
// 13. ANALYTICS
// ============================================================================

class AnalyticsTab extends StatelessWidget {
  const AnalyticsTab({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.user;
    if (user == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final totalViews =
        state.videos.fold<int>(0, (s, v) => s + v.viewCount);
    final totalLikes =
        state.videos.fold<int>(0, (s, v) => s + v.likeCount);
    final totalComments =
        state.videos.fold<int>(0, (s, v) => s + v.commentCount);
    final totalShares =
        state.videos.fold<int>(0, (s, v) => s + v.shareCount);
    final avgEngagement = totalViews == 0
        ? 0.0
        : ((totalLikes + totalComments + totalShares) /
                totalViews *
                100);

    return RefreshIndicator(
      onRefresh: state.refreshAll,
      color: const Color(0xFFFE2C55),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Analytics',
              style:
                  TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Account Info',
                      style: TextStyle(
                          color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 8),
                  _row('Total Followers',
                      _formatNumber(user.followerCount)),
                  _row('Total Likes', _formatNumber(user.likesCount)),
                  _row('Video Count', _formatNumber(user.videoCount)),
                  _row('Verification',
                      user.isVerified ? 'Verified ✅' : 'Not verified'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'Last ${state.videos.length} Videos Summary',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 8),
                  _row('Total Views', _formatNumber(totalViews)),
                  _row('Total Likes', _formatNumber(totalLikes)),
                  _row('Total Comments', _formatNumber(totalComments)),
                  _row('Total Shares', _formatNumber(totalShares)),
                  _row('Avg. Engagement',
                      '${avgEngagement.toStringAsFixed(2)}%'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Session & Authorization',
                      style: TextStyle(
                          color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 8),
                  _row('Open ID', user.openId),
                  _row('Union ID', user.unionId),
                  _row(
                    'Token Expiry',
                    DateFormat('yyyy-MM-dd HH:mm').format(
                      state.tokens?.issuedAt.add(Duration(
                              seconds:
                                  state.tokens?.expiresIn ?? 86400)) ??
                          DateTime.now(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13))),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      );
}

// ============================================================================
// 14. SETTINGS
// ============================================================================

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Settings',
            style:
                TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Refresh All Data'),
            trailing: state.isLoadingUser || state.isLoadingVideos
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: state.refreshAll,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Refresh Token'),
            subtitle: const Text('Use refresh_token'),
            onTap: () async {
              try {
                await state.authService.refreshToken();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Token refreshed')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e')),
                  );
                }
              }
            },
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: const Text('Logout',
                style: TextStyle(color: Colors.redAccent)),
            subtitle: const Text(
                'Revokes token and clears local session'),
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Logout'),
                  content: const Text(
                      'This will revoke your TikTok access token and clear the local session.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Logout')),
                  ],
                ),
              );
              if (confirm == true) await state.logout();
            },
          ),
        ),
        const SizedBox(height: 24),
        const Center(
          child: Text(
            'REQUEST v2.0.0\nUses official TikTok APIs (OAuth 2.0 + PKCE)',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 15. SHARED
// ============================================================================

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, size: 48,
                color: Colors.white38),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}