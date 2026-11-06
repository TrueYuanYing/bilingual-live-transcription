import 'package:dio/dio.dart';

/// Safe diagnostics only: never expose a URL, headers, or provider response.
class AiRequestFailure {
  static String? describe(DioException error) {
    final status = error.response?.statusCode;
    if (status == 408 || status == 504) {
      return 'AI 服务响应超时（HTTP $status），请稍后重试。';
    }
    if (status != null && status >= 500 && status <= 599) {
      return 'AI 服务暂时不可用（HTTP $status），请稍后重试；这不代表设备断网。';
    }
    if (error.type == DioExceptionType.badCertificate ||
        error.error.toString().contains('HandshakeException') ||
        error.error.toString().contains('CERTIFICATE_VERIFY_FAILED')) {
      return 'AI 连接的 TLS 证书验证失败，请检查设备日期、网络代理或更换网络。';
    }
    if (error.type == DioExceptionType.connectionError) {
      if (error.error.toString().contains('Failed host lookup')) {
        return 'AI 服务域名解析失败（DNS），请检查私人 DNS、代理或更换网络后重试。';
      }
      return '无法建立 AI 连接，请检查此网络是否能访问 API 服务；其他网页可用不代表 API 可达。';
    }
    if ([
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout
    ].contains(error.type)) {
      return 'AI 请求超时，请稍后重试，可取消后重新生成。';
    }
    return null;
  }
}
