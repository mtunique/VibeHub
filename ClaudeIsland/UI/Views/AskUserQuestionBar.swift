//
//  AskUserQuestionBar.swift
//  ClaudeIsland
//
//  OpenCode: render question.asked inside the notch.
//

import SwiftUI

struct AskUserQuestionPayload: Sendable {
    struct Option: Sendable {
        let label: String
        let description: String?
    }

    struct Question: Sendable {
        let header: String
        let question: String
        let options: [Option]
        let multiple: Bool
    }

    let questions: [Question]

    static func from(toolInput: [String: AnyCodable]?) -> AskUserQuestionPayload? {
        guard let toolInput else { return nil }
        guard let rawQuestions = toolInput["questions"]?.value as? [Any] else { return nil }

        var questions: [Question] = []

        for qAny in rawQuestions {
            guard let q = qAny as? [String: Any] else { continue }
            let header = (q["header"] as? String) ?? ""
            let question = (q["question"] as? String) ?? ""
            let multiple = (q["multiSelect"] as? Bool) ?? (q["multiple"] as? Bool) ?? false

            var options: [Option] = []
            if let opts = q["options"] as? [Any] {
                for oAny in opts {
                    guard let o = oAny as? [String: Any] else { continue }
                    let label = (o["label"] as? String) ?? ""
                    let desc = (o["description"] as? String)
                    if !label.isEmpty {
                        options.append(Option(label: label, description: desc))
                    }
                }
            }

            // Skip empty questions
            if question.isEmpty && options.isEmpty { continue }
            questions.append(Question(header: header, question: question, options: options, multiple: multiple))
        }

        guard !questions.isEmpty else { return nil }
        return AskUserQuestionPayload(questions: questions)
    }
}

struct AskUserQuestionBar: View {
    let payload: AskUserQuestionPayload
    let onSubmit: ([[String]]) -> Void
    let onUseTerminal: () -> Void

    @State private var selections: [Int: Set<Int>] = [:]

    private func isSelected(q: Int, o: Int) -> Bool {
        selections[q]?.contains(o) ?? false
    }

    private func toggle(q: Int, o: Int) {
        let question = payload.questions[q]
        if question.multiple {
            var set = selections[q] ?? []
            if set.contains(o) {
                set.remove(o)
            } else {
                set.insert(o)
            }
            selections[q] = set
        } else {
            selections[q] = [o]
        }
    }

    private var canSubmit: Bool {
        selections.values.contains { !$0.isEmpty }
    }

    private func buildAnswers() -> [[String]] {
        var answers: [[String]] = []

        for (qi, q) in payload.questions.enumerated() {
            let idxs = selections[qi] ?? []
            var labels: [String] = []
            for i in idxs.sorted() {
                guard i >= 0 && i < q.options.count else { continue }
                labels.append(q.options[i].label)
            }
            if !labels.isEmpty {
                answers.append(labels)
            }
        }

        return answers
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(payload.questions.enumerated()), id: \.offset) { qi, q in
                        VStack(alignment: .leading, spacing: 6) {
                            if !q.header.isEmpty {
                                Text(q.header)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                            }

                            if !q.question.isEmpty {
                                Text(q.question)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(q.options.enumerated()), id: \.offset) { oi, opt in
                                    Button {
                                        toggle(q: qi, o: oi)
                                    } label: {
                                        HStack(alignment: .center, spacing: 10) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 6)
                                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                                                    .frame(width: 18, height: 18)
                                                if isSelected(q: qi, o: oi) {
                                                    Image(systemName: q.multiple ? "checkmark" : "circle.fill")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundColor(.white.opacity(0.9))
                                                }
                                            }

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(opt.label)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.white.opacity(0.95))
                                                if let desc = opt.description, !desc.isEmpty {
                                                    Text(desc)
                                                        .font(.system(size: 11))
                                                        .foregroundColor(.white.opacity(0.55))
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                            }

                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(isSelected(q: qi, o: oi) ? 0.10 : 0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, qi == 0 ? 2 : 0)
                    }
                }
                .padding(.bottom, 8)
            }

            HStack(spacing: 10) {
                Button {
                    onUseTerminal()
                } label: {
                    Text("Use terminal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    onSubmit(buildAnswers())
                } label: {
                    Text("Submit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(canSubmit ? 0.95 : 0.35))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .frame(minHeight: 120)
        .background(Color.black.opacity(0.2))
    }
}
