import Foundation
import UIKit

struct ImageUpload {
    let data: Data
    let filename: String
    let mimeType: String

    static func prepare(data: Data, filename: String) throws -> ImageUpload {
        var result = data
        var ext: String
        var mime: String
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { ext = "png"; mime = "image/png" }
        else if data.starts(with: [0xff, 0xd8, 0xff]) { ext = "jpg"; mime = "image/jpeg" }
        else if data.starts(with: Array("GIF8".utf8)) { ext = "gif"; mime = "image/gif" }
        else if data.count >= 12, String(data: data[8..<12], encoding: .ascii) == "WEBP" { ext = "webp"; mime = "image/webp" }
        else {
            guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else { throw AppError.decoding("不支持的图片格式") }
            result = jpeg; ext = "jpg"; mime = "image/jpeg"
        }
        guard result.count <= 5 * 1024 * 1024 else { throw AppError.decoding("图片不能超过 5 MB，请先压缩图片") }
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return ImageUpload(data: result, filename: "\(stem).\(ext)", mimeType: mime)
    }
}
