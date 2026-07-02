// Error: a tiny owned error value for APIs that want more context than a bare i32 code.

pub struct Error {
    pub code: i32,
    message: *mut String,
}

extern "C" {
    fn malloc(size: usize) *mut void;
    fn free(ptr: *mut void) void;
    fn abort() void;
}

extend Error {
    fn own_message(message: String) *mut String {
        let p = unsafe malloc(sizeof(String)) as *mut String;
        if (p as *mut void) == null {
            unsafe abort();
        }
        unsafe p[0] = message;
        return p;
    }

    pub fn new(code: i32, message: str) Error {
        return Error { code: code, message: Error::own_message(String::from_str(message)) };
    }

    pub fn from_string(code: i32, message: String) Error {
        return Error { code: code, message: Error::own_message(message) };
    }

    pub fn message(self: &Error) &String {
        return unsafe &self.message[0];
    }
}

extend Error as Free {
    pub fn free(self: &mut Error) {
        if (self.message as *mut void) != null {
            unsafe self.message[0].free();
            unsafe free(self.message as *mut void);
            self.message = null;
        }
    }
}

extend Error as Clone {
    pub fn clone(self: &Error) Error {
        return Error { code: self.code, message: Error::own_message(unsafe self.message[0].clone()) };
    }
}

extend Error as Format {
    pub fn fmt(self: &Error) String {
        let mut out = String::from_str("Error(");
        out.push_i64(self.code as i64);
        out.push_str(": ");
        out.push_string(unsafe &self.message[0]);
        out.push_str(")");
        return out;
    }
}
