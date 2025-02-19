import Foundation

actor OllamaService {
    static let shared = OllamaService()
    private let baseURL = "http://localhost:11434/api"
    
    private init() {}
    
    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct Context {
        static let systemPrompt = """
        You are a helpful assistant. Be clear and direct in your responses.
        """
        
        static let contextTemplate = """
        [SYSTEM]
        \(systemPrompt)
        [/SYSTEM]
        
        {history}
        
        [HUMAN]
        {input}
        [/HUMAN]
        
        [ASSISTANT]
        """
    }

    private func formatContext(_ messages: [ChatMessage]) -> String {
        let history = messages.map { message in
            switch message.role {
                case .user: return message.content
                case .assistant: return message.content
                case .system: return message.content
            }
        }.joined(separator: "\n\n")
        
        return Context.contextTemplate
            .replacingOccurrences(of: "{history}", with: history)
    }
    
    private func cleanResponse(_ response: String) -> String {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove role tags and their content
        let roleTags = ["[HUMAN]", "[ASSISTANT]", "[SYSTEM]"]
        for tag in roleTags {
            while let range = cleaned.range(of: "\\[\(tag)\\].*?\\[\\/\(tag)\\]", options: .regularExpression) {
                cleaned.removeSubrange(range)
            }
            cleaned = cleaned.replacingOccurrences(of: tag, with: "")
            cleaned = cleaned.replacingOccurrences(of: "[\(tag)]", with: "")
            cleaned = cleaned.replacingOccurrences(of: "[/\(tag)]", with: "")
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func generateResponse(prompt: String, messages: [ChatMessage], model: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "\(baseURL)/generate") else {
            throw URLError(.badURL)
        }
        
        // Format the context with the template
        let formattedContext = formatContext(messages)
        let fullPrompt = formattedContext.replacingOccurrences(of: "{input}", with: prompt)
        
        if ProcessInfo.processInfo.environment["DEBUG"] != nil {
            print("Full prompt being sent:")
            print("---START OF PROMPT---")
            print(fullPrompt)
            print("---END OF PROMPT---")
        }
        
        let body: [String: Any] = [
            "model": model,
            "prompt": fullPrompt,
            "stream": true,
            "options": [
                "temperature": 0.7,
                "top_p": 0.9,
                "top_k": 40,
                "repeat_penalty": 1.1
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        print("Sending request to Ollama with body: \(body)")
        print("Request JSON: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    print("Starting stream request to URL: \(url.absoluteString)")
                    let (stream, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    
                    print("Got response with status code: \(httpResponse.statusCode)")
                    
                    if !(200...299).contains(httpResponse.statusCode) {
                        var errorMessage = "HTTP Error \(httpResponse.statusCode)"
                        for try await line in stream.lines {
                            if let data = line.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let error = json["error"] as? String {
                                errorMessage = error
                                break
                            }
                        }
                        throw NSError(domain: "OllamaError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                    }
                    
                    var hasReceivedContent = false
                    var isFirstChunk = true
                    
                    for try await line in stream.lines {
                        print("Received line: \(line)")
                        
                        guard let data = line.data(using: .utf8) else {
                            print("Could not convert line to data: \(line)")
                            continue
                        }
                        
                        do {
                            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                print("Parsed JSON: \(json)")
                                if let response = json["response"] as? String {
                                    if !response.isEmpty {
                                        hasReceivedContent = true
                                        
                                        // Only clean the first chunk to remove potential "Assistant:" prefix
                                        let processedResponse = isFirstChunk ? cleanResponse(response) : response
                                        isFirstChunk = false
                                        
                                        continuation.yield(processedResponse)
                                    }
                                }
                                
                                if let done = json["done"] as? Bool, done {
                                    print("Stream completed")
                                    if !hasReceivedContent {
                                        throw NSError(domain: "OllamaError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model failed to generate a response. Please try again."])
                                    }
                                    continuation.finish()
                                    return
                                }
                            }
                        } catch {
                            print("Failed to parse JSON: \(error)")
                            print("Raw data: \(String(data: data, encoding: .utf8) ?? "")")
                            continue
                        }
                    }
                    
                    if !hasReceivedContent {
                        throw NSError(domain: "OllamaError", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response received from the model"])
                    }
                    continuation.finish()
                } catch {
                    print("Stream error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    func listModels() async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/tags") else {
            throw URLError(.badURL)
        }
        
        print("Fetching models from URL: \(url.absoluteString)")
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        print("Models response status code: \(httpResponse.statusCode)")
        print("Models response data: \(String(data: data, encoding: .utf8) ?? "")")
        
        if !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        
        struct ModelResponse: Codable {
            let models: [Model]
            
            struct Model: Codable {
                let name: String
            }
        }
        
        let modelResponse = try JSONDecoder().decode(ModelResponse.self, from: data)
        let models = modelResponse.models.map { $0.name }
        print("Available models: \(models)")
        return models
    }
    
    func pullModel(name: String) async throws {
        guard let url = URL(string: "\(baseURL)/pull") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "name": name,
            "stream": false
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
