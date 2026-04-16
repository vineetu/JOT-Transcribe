#!/usr/bin/env swift
// Usage: GEMINI_API_KEY=... swift scripts/test-llm.swift

import Foundation

guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty else {
    print("ERROR: Set GEMINI_API_KEY environment variable")
    exit(1)
}

let model = "gemini-2.0-flash"
let baseURL = "https://generativelanguage.googleapis.com/v1beta"

let systemPrompt = """
    You are a text rewriting assistant. You receive selected text and a voice instruction. \
    Rewrite the text according to the instruction. Output ONLY the rewritten text — no explanations, \
    no quotes, no markdown formatting, no preamble.
    """

let userPrompt = """
    Selected text:
    ---
    hello world this is a test
    ---

    Instruction: make it formal
    """

let combinedPrompt = "System: \(systemPrompt)\n\nUser: \(userPrompt)"

let body: [String: Any] = [
    "contents": [
        ["parts": [["text": combinedPrompt]]]
    ],
    "generationConfig": ["temperature": 0.3],
]

guard let url = URL(string: "\(baseURL)/models/\(model):generateContent?key=\(apiKey)") else {
    print("ERROR: Invalid URL")
    exit(1)
}

var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = try JSONSerialization.data(withJSONObject: body)

let semaphore = DispatchSemaphore(value: 0)

let task = URLSession.shared.dataTask(with: request) { data, response, error in
    defer { semaphore.signal() }

    if let error = error {
        print("ERROR: \(error.localizedDescription)")
        return
    }

    guard let data = data else {
        print("ERROR: No data received")
        return
    }

    guard let httpResponse = response as? HTTPURLResponse else {
        print("ERROR: Invalid response")
        return
    }

    guard (200...299).contains(httpResponse.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
        print("ERROR: HTTP \(httpResponse.statusCode): \(body)")
        return
    }

    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String
        else {
            print("ERROR: Unexpected response format")
            print(String(data: data, encoding: .utf8) ?? "<unreadable>")
            return
        }
        print("Rewrite result: \(text)")
    } catch {
        print("ERROR: JSON parsing failed: \(error)")
    }
}

task.resume()
semaphore.wait()
