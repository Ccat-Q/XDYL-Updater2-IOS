import Foundation

/// Business credentials and bodies may only follow redirects within the same
/// official origin. The separate developer executor retains custom URL support.
final class BusinessRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static func isAllowed(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        if url.scheme?.lowercased() == "https", (url.port ?? 443) == 443,
           ["login.lanternwaves.fun", "api.lanternwaves.fun", "api.github.com", "github.com"].contains(host) { return true }
        return url.scheme?.lowercased() == "http" && host == "api.lanternwaves.fun" && [8080, 5551].contains(url.port ?? 80)
    }

    static func permits(from source: URL, to target: URL) -> Bool {
        isAllowed(source) && isAllowed(target)
            && source.scheme?.lowercased() == target.scheme?.lowercased()
            && source.host?.lowercased() == target.host?.lowercased()
            && effectivePort(source) == effectivePort(target)
    }

    private static func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let source = response.url, let target = request.url,
              Self.permits(from: original, to: target), Self.permits(from: source, to: target) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
