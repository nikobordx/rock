/*
  For bestest backtraces, pass `-g +-rdynamic` to rock when compiling.

  gcc's documentation for -rdynamic:
        -rdynamic
           Pass the flag -export-dynamic to the ELF linker, on targets that
           support it. This instructs the linker to add all symbols, not only
           used ones, to the dynamic symbol table. This option is needed for
           some uses of "dlopen" or to allow obtaining backtraces from within a
           program.

 */
import threading/Thread, structs/Stack, structs/LinkedList
import native/win32/errors

include setjmp, assert, errno

version(linux) {
    include execinfo

    backtrace: extern func (array: Void**, size: Int) -> Int
    backtraceSymbols: extern(backtrace_symbols) func (array: const Void**, size: Int) -> Char**
    backtraceSymbolsFd: extern(backtrace_symbols_fd) func (array: const Void**, size: Int, fd: Int)
}

JmpBuf: cover from jmp_buf {
    setJmp: extern(setjmp) func -> Int
    longJmp: extern(longjmp) func (value: Int)
}

BACKTRACE_LENGTH := 20

_StackFrame: cover {
    buf: JmpBuf
}

StackFrame: cover from _StackFrame* {
    new: static func -> This {
        gc_malloc(_StackFrame size)
    }
}

exceptionStack := ThreadLocal<Stack<StackFrame>> new()

_exception := ThreadLocal<Exception> new()
_EXCEPTION: Int = 1

_pushStackFrame: inline func -> StackFrame {
    stack: Stack<StackFrame>
    if(!exceptionStack hasValue?()) {
        stack = Stack<StackFrame> new()
        exceptionStack set(stack)
    } else {
        stack = exceptionStack get()
    }
    buf := StackFrame new()
    stack push(buf)
    buf
}

_setException: inline func (e: Exception) {
    _exception set(e)
}

_getException: inline func -> Exception {
    _exception get()
}

_popStackFrame: inline func -> StackFrame {
    exceptionStack get() as Stack<StackFrame> pop() as StackFrame
}

_hasStackFrame: inline func -> Bool {
    exceptionStack hasValue?() && exceptionStack get() as Stack<StackFrame> size > 0
}

assert: extern func(Bool)

version(windows) {
    DWORD: cover from Long
    LPTSTR: cover from CString
    FormatMessage: extern func(dwFlags: DWORD, lpSource: Pointer, dwMessageId: DWORD, dwLanguageId: DWORD,
        lpBuffer: LPTSTR, nSize: DWORD, Arguments: VaList*) -> DWORD
    FORMAT_MESSAGE_FROM_SYSTEM: extern Long
    FORMAT_MESSAGE_IGNORE_INSERTS: extern Long
    FORMAT_MESSAGE_ARGUMENT_ARRAY: extern Long
    getOSErrorCode: func -> Int {
        GetLastError()
    }
    getOSError: func -> String {
        err : DWORD = GetLastError()
        BUF_SIZE := 256
        buf := Buffer new(BUF_SIZE)
        len : SSizeT = FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS | FORMAT_MESSAGE_ARGUMENT_ARRAY,
            null, err, 0, buf data as CString, BUF_SIZE, null)
        buf setLength(len)
        // rip away trailing CR LF TAB SPACES etc.
        while ((len > 0) && (buf[len - 1] as Octet < 32)) len -= 1
        buf setLength(len)
        buf toString()
    }
} else {
    errno: extern Int
    strerror: extern func (Int) -> CString

    getOSErrorCode: func -> Int {
        errno
    }

    getOSError: func -> String {
        x := strerror(errno)
        return (x != null) ? x toString() : ""
    }
}

raise: func(msg: String) {
    Exception new(msg) throw()
}

raise: func~withClass(clazz: Class, msg: String) {
    Exception new(clazz, msg) throw()
}

Backtrace: class {
    length: Int
    buffer: Pointer*
    init: func(=length, =buffer) {}
}

/**
 * Base class for all exceptions that can be thrown
 *
 * @author Amos Wenger (nddrylliog)
 */
Exception: class {
    backtraces: LinkedList<Backtrace> = LinkedList<Backtrace> new()

    addBacktrace: func {
        version(linux) {
            backtraceBuffer := gc_malloc(Pointer size * BACKTRACE_LENGTH)
            backtraceLength := backtrace(backtraceBuffer, BACKTRACE_LENGTH)
            backtraces add(Backtrace new(backtraceLength, backtraceBuffer))
        }
        // TODO: other platforms
    }

    printBacktrace: func {
        version(linux) {
            if (!backtraces empty?()) {
                fprintf(stderr, "[backtrace]\n")
            }

            first := true

            for (backtrace in backtraces) {
                if (first) {
                    first = false
                } else {
                    fprintf(stderr, "[rethrow]\n")
                }
                
                if(backtrace buffer != null) {
                    backtraceSymbolsFd(backtrace buffer, backtrace length, 2) // hell yeah stderr fd.
                }
            }
        }
        // TODO: other platforms
    }

    /** Class which threw the exception. May be null */
    origin: Class

    /** Message associated with this exception. Printed when the exception is thrown. */
    message : String

    /**
     * Create an exception
     *
     * @param origin The class throwing this exception
     * @param message A short text explaning why the exception was thrown
     */
    init: func  (=origin, =message) {
    }

    /**
     * Create an exception
     *
     * @param message A short text explaning why the exception was thrown
     */
    init: func ~noOrigin (=message) {
    }


    /**
     * @return the exception's message, nicely formatted
     */
    formatMessage: func -> String {
        if(origin)
            "[%s in %s]: %s\n" format(class name toCString(), origin name toCString(), message ? message toCString() : "<no message>" toCString())
        else
            "[%s]: %s\n" format(class name toCString(), message ? message toCString() : "<no message>" toCString())
    }

    /**
     * Print this exception, with its origin, if specified, and its message
     */
    print: func {
        fprintf(stderr, "%s", formatMessage() toCString())
        printBacktrace()
    }

    /**
     * Throw this exception
     */
    throw: func {
        _setException(this)
        addBacktrace()
        if(!_hasStackFrame()) {
            print()
            abort()
        } else {
            frame := _popStackFrame()
            frame@ buf longJmp(_EXCEPTION)
        }
    }

    /**
     * Rethrow this exception.
     */
    rethrow: func {
        throw()
    }
}

OSException: class extends Exception {
    init: func (=message) {
        init()
    }
    init: func ~noOrigin {
        x := getOSError()
        if ((message != null) && (!message empty?())) {
            message = message append(':') append(x)
        } else message = x
    }
}

OutOfBoundsException: class extends Exception {
    init: func (=origin, accessOffset: SizeT, elementLength: SizeT) {
        init(accessOffset, elementLength)
    }
    init: func ~noOrigin (accessOffset: SizeT, elementLength: SizeT) {
        message = "Trying to access an element at offset %d, but size is only %d!" format(accessOffset,elementLength)
    }
}

OutOfMemoryException: class extends Exception {
    init: func (=origin) {
        init()
    }
    init: func ~noOrigin {
        message = "Failed to allocate more memory!"
    }
}

/* ------ C interfacing ------ */

include stdlib

/** stdlib.h -
 *
 * The  abort() first unblocks the SIGABRT signal, and then raises that
 * signal for the calling process.  This results in the abnormal
 * termination of the process unless the SIGABRT signal is caught
 * and the signal handler does not return (see longjmp(3)).
 *
 * If the abort() function causes process termination, all open streams
 * are closed and flushed.
 *
 * If the SIGABRT signal is ignored, or caught by a handler that returns,
 * the abort() function will still terminate the process.  It does this
 * by restoring the default disposition for SIGABRT and then raising
 * the signal for a second time.
 */
abort: extern func

