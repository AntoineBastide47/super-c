// Error: a tiny owned error value for APIs that want more context than a bare i32 code.

/// A code plus an owned message; clones deep-copy the message.
pub struct Error {
    pub code: i32,
    message: String,
}

extend Error {
    /// Copies `message`'s bytes into an owned String the Error frees.
    pub fn new(code: i32, message: str) Error {
        return Error { code: code, message: String::from_str(message) };
    }

    /// Takes ownership of `message` (no byte copy).
    pub fn from_string(code: i32, message: String) Error {
        return Error { code: code, message: message };
    }

    /// The message text.
    pub fn message(self: &Error) &String {
        return &self.message;
    }
}

extend Error as Clone {
    pub fn clone(self: &Error) Error {
        return Error { code: self.code, message: self.message.clone() };
    }
}

extend Error as Format {
    pub fn fmt(self: &Error) String {
        let mut out = String::from_str("Error(");
        out.push_i64(self.code);
        out.push_str(": ");
        out.push_string(&self.message);
        out.push_str(")");
        return out;
    }
}
