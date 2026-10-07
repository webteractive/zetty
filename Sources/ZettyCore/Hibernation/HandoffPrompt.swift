import Foundation

/// What a forked session is asked for, and what the fresh agent is first told.
public enum HandoffPrompt {
    public static let request = """
        This project is being hibernated. Reply with a handoff for a fresh agent that will pick \
        this work up later and remembers nothing of this conversation.

        Cover, in plain Markdown under short headings: the goal; what's done; the current state, \
        naming every file that matters by its full path; decisions made and why; open questions; \
        the next steps; and anything the person asked you to remember. Keep it under about two \
        pages. Never put passwords, keys, tokens or other secrets in it.

        Do no other work. Change no files, run nothing, and ask nothing: nobody is watching. \
        Reply with the handoff only.
        """

    public static let wakeLine = """
        This project was hibernated, and you're picking it up in a fresh conversation. Below is \
        the handoff you wrote before it was put away. Read it, then tell the person in a sentence \
        or two where things stand, and wait for them.
        """

    /// The text must be IN the file the first message mentions: a mention
    /// inside a mentioned file is not expanded.
    public static func wakeFile(handoff: String) -> String {
        "\(wakeLine)\n\n---\n\n\(handoff.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

public enum HandoffOutput {
    /// Larger is most of a transcript, which is what a handoff replaces.
    public static let maxBytes = 200_000

    /// The handoff a finished fork produced, or nil: a failed run, an empty
    /// reply, one over the cap, or bytes that are not text.
    public static func accepted(exitCode: Int32, stdout: Data) -> String? {
        guard exitCode == 0, stdout.count <= maxBytes,
              let text = String(data: stdout, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
