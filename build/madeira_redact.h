/* madeira_redact.h -- credential-like values out of the command lines Madeira logs.
 *
 * Madeira logs the command line of the programs it starts: ntdll's
 * spawn_process and NtCreateUserProcess lines, the environment trace and the
 * app's [WineProc] argv lines. A launcher can hand the program it starts a
 * sign-in token, a password or a session value on that command line, and
 * session logs are attached to bug reports. These functions make the copy such
 * a line prints: credential-like values become "<redacted>", everything else is
 * copied unchanged, whitespace included. The command line the program receives
 * is never touched.
 *
 * What is hidden (the value only; the name before it stays readable):
 *   - the value of an option or key whose name ends in token, password, passwd,
 *     passphrase, secret, ticket, apikey, sessionid, sessionkey, credential(s),
 *     authcode or authorization, or is pass or pwd, compared ignoring case and
 *     the separators '_', '-' and '.'. The forms are -name VALUE, --name VALUE,
 *     /name VALUE and +name VALUE, the same with '=' or ':' instead of the
 *     space, name=VALUE and name:VALUE, and ?name=VALUE or &name=VALUE inside
 *     an argument (a URL's query);
 *   - a value shaped like a signed ticket or bearer token: alone, after any
 *     -name= or -name: (or a bare name=), or as a URL query value. A ticket is
 *     four or more colon-separated fields ending in a field of 16 or more
 *     characters; a bearer token is three or more dot-separated base64url parts
 *     starting with "eyJ" (an encoded '{"').
 * The value of a credential option given on its own (or with '=' and nothing
 * after it) is the next argument, whatever it looks like. A hidden value runs
 * to the end of its argument (in a URL query, the rest of the argument), so a
 * quoted value is hidden up to its closing quote, spaces included; the quotes
 * themselves are kept.
 *
 * Header-only and dependency-free, like madeira_cfg.h: included by ntdll unix
 * and the app, and compiled on the host by tests/host/check-log-redaction.py.
 * A file that defines MADEIRA_REDACT_WINE before including it, after Wine's
 * headers, also gets the madeira_debugstr_cmdline_* wrappers at the end. */
#ifndef MADEIRA_REDACT_H
#define MADEIRA_REDACT_H

#include <stddef.h>

#define MADEIRA_REDACTED "<redacted>"

/* One implementation for char and UTF-16 text: w is the code unit size (1 or 2). */
static inline unsigned madeira_redact__at(const void *s, size_t w, size_t i)
{
    return w == 1 ? (unsigned)((const unsigned char *)s)[i] : (unsigned)((const unsigned short *)s)[i];
}

/* Appends c while there is room for it and the terminator. */
static inline int madeira_redact__put(void *out, size_t w, size_t cap, size_t *o, unsigned c)
{
    if (*o + 1 >= cap) return 0;
    if (w == 1) ((char *)out)[*o] = (char)c;
    else ((unsigned short *)out)[*o] = (unsigned short)c;
    (*o)++;
    return 1;
}

static inline int madeira_redact__space(unsigned c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

static inline int madeira_redact__namechar(unsigned c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           c == '_' || c == '-' || c == '.';
}

static inline int madeira_redact__only_quotes(const void *s, size_t w, size_t x, size_t y)
{
    for (; x < y; x++) if (madeira_redact__at(s, w, x) != '"') return 0;
    return 1;
}

/* Does the name s[b..e) end in word (lower case), ignoring case and the separators
 * '_', '-' and '.'? With whole, the word must be all of it. */
static inline int madeira_redact__name_is(const void *s, size_t w, size_t b, size_t e,
                                          const char *word, int whole)
{
    size_t k = 0;

    while (word[k]) k++;
    while (k && e > b)
    {
        unsigned c = madeira_redact__at(s, w, --e);
        if (c == '_' || c == '-' || c == '.') continue;
        if (c >= 'A' && c <= 'Z') c += 32u;
        if (c != (unsigned char)word[--k]) return 0;
    }
    if (k) return 0;
    while (whole && e > b)
    {
        unsigned c = madeira_redact__at(s, w, --e);
        if (c != '_' && c != '-' && c != '.') return 0;
    }
    return 1;
}

static inline int madeira_redact__credential_name(const void *s, size_t w, size_t b, size_t e)
{
    static const char *const ends[] =
    {
        "token", "password", "passwd", "passphrase", "secret", "ticket", "apikey", "sessionid",
        "sessionkey", "credential", "credentials", "authcode", "authorization", NULL
    };
    static const char *const whole[] = { "pass", "pwd", NULL };
    size_t i;

    for (i = 0; ends[i]; i++) if (madeira_redact__name_is(s, w, b, e, ends[i], 0)) return 1;
    for (i = 0; whole[i]; i++) if (madeira_redact__name_is(s, w, b, e, whole[i], 1)) return 1;
    return 0;
}

/* s[x..y) is shaped like a signed ticket (four or more colon-separated fields,
 * the last one 16 or more characters long) or a signed bearer token (three or
 * more dot-separated base64url parts, the first starting "eyJ"). */
static inline int madeira_redact__secret_shape(const void *s, size_t w, size_t x, size_t y)
{
    size_t i, colons = 0, dots = 0, field = 0;

    if (y <= x) return 0;
    for (i = x; i < y; i++)
    {
        unsigned c = madeira_redact__at(s, w, i);
        if (c == ':') { colons++; field = 0; continue; }
        if (!madeira_redact__namechar(c)) return 0;
        if (c == '.') dots++;
        field++;
    }
    if (colons >= 3 && field >= 16) return 1;
    return !colons && dots >= 2 && y - x >= 40 && madeira_redact__at(s, w, x) == 'e' &&
           madeira_redact__at(s, w, x + 1) == 'y' && madeira_redact__at(s, w, x + 2) == 'J';
}

/* The double-quote state after s[x..y), starting from q. Windows rules: a quote
 * after an odd number of backslashes is a literal quote. */
static inline int madeira_redact__quoted(const void *s, size_t w, size_t x, size_t y, int q)
{
    size_t bs = 0;

    for (; x < y; x++)
    {
        unsigned c = madeira_redact__at(s, w, x);
        if (c == '"' && !(bs & 1)) q = !q;
        bs = c == '\\' ? bs + 1 : 0;
    }
    return q;
}

/* The end of the argument that continues at i in quote state q: the first
 * whitespace outside double quotes. */
static inline size_t madeira_redact__arg_end(const void *s, size_t w, size_t n, size_t i, int q)
{
    size_t bs = 0;

    for (; i < n; i++)
    {
        unsigned c = madeira_redact__at(s, w, i);
        if (!c || (!q && madeira_redact__space(c))) break;
        if (c == '"' && !(bs & 1)) q = !q;
        bs = c == '\\' ? bs + 1 : 0;
    }
    return i;
}

/* One whitespace-separated word s[ts..te). Returns where its hidden value starts,
 * or te when nothing in it is hidden. *pending: on entry, the word before was a
 * credential option whose value is this word; on return, this word is one. */
static inline size_t madeira_redact__find(const void *s, size_t w, size_t ts, size_t te, int *pending)
{
    size_t a = ts, end = te, b, e, i, k;
    unsigned sep;

    if (*pending)
    {
        *pending = 0;
        return madeira_redact__only_quotes(s, w, ts, te) ? te : ts;
    }
    while (a < end && madeira_redact__at(s, w, a) == '"') a++;
    while (end > a && madeira_redact__at(s, w, end - 1) == '"') end--;

    /* -name, --name, /name, +name; or a bare word: a ticket or token itself, or name=value */
    b = a;
    if (b < end && (madeira_redact__at(s, w, b) == '-' || madeira_redact__at(s, w, b) == '/' ||
                    madeira_redact__at(s, w, b) == '+'))
        b += (madeira_redact__at(s, w, b) == '-' && b + 1 < end && madeira_redact__at(s, w, b + 1) == '-') ? 2 : 1;
    else if (madeira_redact__secret_shape(s, w, a, end))
        return a;
    for (e = b; e < end && madeira_redact__namechar(madeira_redact__at(s, w, e)); e++) ;
    sep = e < end ? madeira_redact__at(s, w, e) : 0;
    if (e > b && (sep == '=' || sep == ':'))
    {
        int credential = madeira_redact__credential_name(s, w, b, e);
        if (madeira_redact__only_quotes(s, w, e + 1, te))
        {
            if (credential) *pending = 1;          /* -name= VALUE (and -name="": the next word too) */
            return te;
        }
        if (credential || ((b > a || sep == '=') && madeira_redact__secret_shape(s, w, e + 1, end)))
            return e + 1;
    }
    else if (e > b && e == end && b > a && madeira_redact__credential_name(s, w, b, e))
    {
        *pending = 1;                              /* -name VALUE */
        return te;
    }

    /* ?name=value or &name=value inside the word: a URL's query */
    for (i = a; i < end; i++)
    {
        size_t v;
        if (madeira_redact__at(s, w, i) != '?' && madeira_redact__at(s, w, i) != '&') continue;
        for (k = i + 1; k < end && madeira_redact__namechar(madeira_redact__at(s, w, k)); k++) ;
        if (k == i + 1 || k + 1 >= end || madeira_redact__at(s, w, k) != '=') continue;
        for (v = k + 1; v < end && madeira_redact__at(s, w, v) != '&'; v++) ;
        if (madeira_redact__credential_name(s, w, i + 1, k) || madeira_redact__secret_shape(s, w, k + 1, v))
            return k + 1;
    }
    return te;
}

/* The redacted copy of s[0..n) into out: at most cap - 1 units and a terminator;
 * a copy that does not fit ends in "...". Stops at a NUL. *pending carries a
 * credential option whose value is still to come between calls. With to_end, a
 * hidden value runs to the end of s (s is a single argument). Returns the length. */
static inline size_t madeira_redact__copy(const void *s, size_t w, size_t n, void *out, size_t cap,
                                          int *pending, int to_end)
{
    size_t i = 0, o = 0, k;
    int open = 0, full = 0;

    if (!cap) return 0;
    while (i < n && !full)
    {
        unsigned c = madeira_redact__at(s, w, i);
        size_t ts, te, vs, ve, q;
        int was_pending = *pending;

        if (!c) break;
        if (madeira_redact__space(c))
        {
            full = !madeira_redact__put(out, w, cap, &o, c);
            i++;
            continue;
        }
        for (ts = i; i < n && (c = madeira_redact__at(s, w, i)) && !madeira_redact__space(c); i++) ;
        te = i;
        vs = madeira_redact__find(s, w, ts, te, pending);
        if (vs == te)
        {
            /* an option that leaves a quote open: its value starts inside the quote */
            if (*pending) open = madeira_redact__quoted(s, w, ts, te, 0);
            for (k = ts; k < te && !full; k++) full = !madeira_redact__put(out, w, cap, &o, madeira_redact__at(s, w, k));
            continue;
        }
        ve = to_end ? n : madeira_redact__arg_end(s, w, n, vs, madeira_redact__quoted(s, w, ts, vs, was_pending && open));
        i = ve;
        for (k = ts; k < vs && !full; k++) full = !madeira_redact__put(out, w, cap, &o, madeira_redact__at(s, w, k));
        for (q = vs; q < ve && madeira_redact__at(s, w, q) == '"' && !full; q++) full = !madeira_redact__put(out, w, cap, &o, '"');
        for (k = 0; MADEIRA_REDACTED[k] && !full; k++) full = !madeira_redact__put(out, w, cap, &o, (unsigned char)MADEIRA_REDACTED[k]);
        if (ve > q && madeira_redact__at(s, w, ve - 1) == '"' && !full) full = !madeira_redact__put(out, w, cap, &o, '"');
    }
    if (full && cap > 4)
    {
        if (o > cap - 4) o = cap - 4;
        for (k = 0; k < 3; k++) madeira_redact__put(out, w, cap, &o, '.');
    }
    if (w == 1) ((char *)out)[o] = 0;
    else ((unsigned short *)out)[o] = 0;
    return o;
}

/* A whole command line, char or UTF-16. */
static inline size_t madeira_redact_line_a(const char *s, size_t n, char *out, size_t cap)
{
    int pending = 0;
    return madeira_redact__copy(s, 1, n, out, cap, &pending, 0);
}

static inline size_t madeira_redact_line_w(const unsigned short *s, size_t n, unsigned short *out, size_t cap)
{
    int pending = 0;
    return madeira_redact__copy(s, 2, n, out, cap, &pending, 0);
}

/* One element of an argv array, logged on a line of its own. *pending carries a
 * credential option's value to the next element (start at 0); that element is
 * hidden whole, spaces included. */
static inline size_t madeira_redact_arg_a(const char *arg, int *pending, char *out, size_t cap)
{
    size_t n = 0, len;
    int value = *pending;

    while (arg[n]) n++;
    len = madeira_redact__copy(arg, 1, n, out, cap, pending, 1);
    if (value) *pending = 0;                       /* an empty element is the (empty) value */
    return len;
}

#ifdef MADEIRA_REDACT_WINE
/* debugstr_wn / debugstr_w / debugstr_us of the redacted copy. debugstr shows a
 * few hundred characters at most, so a bounded copy loses nothing it would show. */
static inline const char *madeira_debugstr_cmdline_wn(const WCHAR *s, size_t n)
{
    unsigned short buf[1024];
    size_t len;

    if (!s) return "(null)";
    len = madeira_redact_line_w((const unsigned short *)s, n, buf, sizeof(buf) / sizeof(buf[0]));
    return debugstr_wn((const WCHAR *)buf, (int)len);
}

static inline const char *madeira_debugstr_cmdline_w(const WCHAR *s)
{
    size_t n = 0;

    while (s && s[n]) n++;
    return madeira_debugstr_cmdline_wn(s, n);
}

static inline const char *madeira_debugstr_cmdline_us(const UNICODE_STRING *us)
{
    if (!us) return "<null>";
    return madeira_debugstr_cmdline_wn(us->Buffer, us->Length / sizeof(WCHAR));
}
#endif

#endif /* MADEIRA_REDACT_H */
