//
//  JSONC.swift
//  AgentRunner
//
//  JSON with Comments — // 라인 주석 + /* */ 블록 주석 + trailing comma 허용.
//  파싱 전에 strip 호출하면 표준 JSON으로 변환됨.
//  문자열 내부 // 등은 안 건드림 (escape \" 처리 포함).
//

import Foundation

enum JSONC {

    static func strip(_ input: String) -> String {
        let chars = Array(input)
        var out = ""
        out.reserveCapacity(chars.count)

        var inString = false
        var escapeNext = false
        var inLine = false
        var inBlock = false

        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil

            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
                i += 1
                continue
            }
            if inBlock {
                if c == "*", next == "/" { inBlock = false; i += 2; continue }
                i += 1
                continue
            }
            if inString {
                out.append(c)
                if escapeNext { escapeNext = false }
                else if c == "\\" { escapeNext = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }

            // 일반 영역
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", next == "/" { inLine = true; i += 2; continue }
            if c == "/", next == "*" { inBlock = true; i += 2; continue }

            out.append(c)
            i += 1
        }

        // trailing comma 제거: ,] 또는 ,} 패턴
        return removeTrailingCommas(out)
    }

    private static func removeTrailingCommas(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var inString = false
        var escapeNext = false

        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                result.append(c)
                if escapeNext { escapeNext = false }
                else if c == "\\" { escapeNext = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; result.append(c); i += 1; continue }
            if c == "," {
                // 다음 non-whitespace가 ] 또는 }면 콤마 skip
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "]" || chars[j] == "}" {
                    i += 1
                    continue
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }
}
