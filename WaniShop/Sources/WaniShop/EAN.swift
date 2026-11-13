import UIKit
import CoreImage.CIFilterBuiltins

private let lCodes = ["0001101","0011001","0010011","0111101","0100011",
                      "0110001","0101111","0111011","0110111","0001011"]
private let gCodes = ["0100111","0110011","0011011","0100001","0011101",
                      "0111001","0000101","0010001","0001001","0010111"]
private let rCodes = ["1110010","1100110","1101100","1000010","1011100",
                      "1001110","1010000","1000100","1001000","1110100"]
private let parityTable = ["LLLLLL","LLGLGG","LLGGLG","LLGGGL","LGLLGG",
                           "LGGLLG","LGGGLL","LGLGLG","LGLGGL","LGGLGL"]

func eanCheckDigit(_ first12: String) -> Int {
    var total = 0
    for (i, ch) in first12.enumerated() {
        let d = Int(String(ch)) ?? 0
        total += d * (i % 2 == 1 ? 3 : 1)
    }
    return (10 - total % 10) % 10
}

/// Returns a valid 13-digit EAN code, or nil if the text is not a valid barcode.
func validEAN(_ raw: String) -> String? {
    var code = trimmed(raw)
    guard !code.isEmpty, code.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
    if code.count == 12 { code = "0" + code }
    guard code.count == 13, let check = Int(String(code.suffix(1))) else { return nil }
    guard eanCheckDigit(String(code.prefix(12))) == check else { return nil }
    return code
}

func eanBits(_ code: String) -> String {
    let d = code.map { Int(String($0)) ?? 0 }
    let pattern = Array(parityTable[d[0]])
    var bits = "101"
    for i in 1...6 {
        bits += (pattern[i - 1] == "L" ? lCodes : gCodes)[d[i]]
    }
    bits += "01010"
    for i in 7...12 {
        bits += rCodes[d[i]]
    }
    return bits + "101"
}

func eanImage(_ code: String) -> UIImage {
    let bits = Array(eanBits(code))
    let w: CGFloat = 240
    let h: CGFloat = 140
    let module: CGFloat = 2
    let x0 = (w - CGFloat(bits.count) * module) / 2
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
    return renderer.image { _ in
        UIColor.white.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: w, height: h))
        UIColor.black.setFill()
        for (i, b) in bits.enumerated() where b == "1" {
            UIRectFill(CGRect(x: x0 + CGFloat(i) * module, y: 10, width: module, height: 96))
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: UIColor.black,
            .paragraphStyle: para,
        ]
        (code as NSString).draw(in: CGRect(x: 0, y: 112, width: w, height: 22), withAttributes: attrs)
    }
}

func qrImage(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    let context = CIContext()
    guard let cg = context.createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

func upiLink(vpa: String, name: String, amount: Double, note: String) -> String {
    func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
    return "upi://pay?pa=\(enc(vpa))&pn=\(enc(name))&am=\(String(format: "%.2f", amount))&cu=INR&tn=\(enc(note))"
}
