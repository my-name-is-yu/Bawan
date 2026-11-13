#!/usr/bin/env swift
// Export the vector master as a transparent, single-page PDF. No third-party tools are needed.
// Usage: swift scripts/generate-status-icon.swift [source.svg] [output.pdf]
// The master uses filled M/L/Z paths and circles; unsupported shapes fail explicitly.
import Foundation
import CoreGraphics

enum ExportError: Error { case invalid(String) }

final class VectorReader: NSObject, XMLParserDelegate {
    var size = CGSize.zero
    var shapes: [(CGPath, Bool)] = []
    var failure: Error?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        do {
            switch elementName {
            case "svg":
                guard let width = attributes["width"].flatMap(Double.init), width > 0,
                      let height = attributes["height"].flatMap(Double.init), height > 0,
                      attributes["viewBox"] == "0 0 \(attributes["width"]!) \(attributes["height"]!)" else {
                    throw ExportError.invalid("Expected a zero-origin viewBox matching width and height")
                }
                size = CGSize(width: width, height: height)
            case "path":
                guard let data = attributes["d"] else { throw ExportError.invalid("Missing path") }
                let tokens = data.split(whereSeparator: { $0.isWhitespace })
                let path = CGMutablePath()
                var index = 0
                while index < tokens.count {
                    let command = tokens[index]
                    index += 1
                    if command == "Z" { path.closeSubpath(); continue }
                    guard (command == "M" || command == "L"), index + 1 < tokens.count,
                          let x = Double(tokens[index]), let y = Double(tokens[index + 1]) else {
                        throw ExportError.invalid("Only space-separated M/L/Z paths are supported")
                    }
                    let point = CGPoint(x: x, y: y)
                    if command == "M" { path.move(to: point) } else { path.addLine(to: point) }
                    index += 2
                }
                shapes.append((path, attributes["fill-rule"] == "evenodd"))
            case "circle":
                guard let x = attributes["cx"].flatMap(Double.init),
                      let y = attributes["cy"].flatMap(Double.init),
                      let radius = attributes["r"].flatMap(Double.init), radius > 0 else {
                    throw ExportError.invalid("Invalid circle")
                }
                let path = CGPath(ellipseIn: CGRect(x: x - radius, y: y - radius,
                    width: radius * 2, height: radius * 2), transform: nil)
                shapes.append((path, false))
            default:
                throw ExportError.invalid("Unsupported SVG element: \(elementName)")
            }
        } catch {
            failure = error
            parser.abortParsing()
        }
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) :
    root.appendingPathComponent("resources/StatusItemTemplate.svg")
let destination = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) :
    root.appendingPathComponent("resources/StatusItemTemplate.pdf")
let reader = VectorReader()
let parser = XMLParser(data: try Data(contentsOf: source))
parser.delegate = reader
guard parser.parse(), reader.size.width > 0, !reader.shapes.isEmpty else {
    throw reader.failure ?? parser.parserError ?? ExportError.invalid("Empty SVG")
}
var page = CGRect(origin: .zero, size: reader.size)
guard let context = CGContext(destination as CFURL, mediaBox: &page, nil) else {
    throw ExportError.invalid("Could not create PDF")
}
context.beginPDFPage(nil)
context.translateBy(x: 0, y: page.height)
context.scaleBy(x: 1, y: -1)
context.setFillColor(CGColor(gray: 0, alpha: 1))
for (path, evenOdd) in reader.shapes {
    context.addPath(path)
    context.drawPath(using: evenOdd ? .eoFill : .fill)
}
context.endPDFPage()
context.closePDF()
print(destination.path)
