import UIKit

/// Helper to enable JIT via StikDebug/StikJIT URL scheme.
/// Opens StikDebug with an embedded script, polls for CS_DEBUGGED,
/// then allocates JIT memory and detaches the debugger.
enum StikJITHelper {

    /// The JIT script, embedded as base64. madeira-jit.js is NOT a member of
    /// the Xcode target, so this literal -- not the file -- is what StikDebug
    /// actually runs. Regenerate it after every edit:
    ///   tools/jit-script-sync.py --write
    /// `tools/jit-script-sync.py` (no args) fails if the two have drifted, so a
    /// JIT fix cannot silently fail to ship. TODO: add madeira-jit.js to Copy
    /// Bundle Resources and delete the literal.
    private static let scriptBase64 = "Ly8gTWFkZWlyYSBKSVQgU2NyaXB0IGZvciBTdGlrRGVidWcKLy8gSGFuZGxlcyBCUksgIzB4ZjAwZCAodW5pdmVyc2FsIHByb3RvY29sKSB3aXRoIHgxNi1iYXNlZCBjb21tYW5kIGRpc3BhdGNoLgovLwovLyBtbDM0NiAodjIpOiBzb2Z0LXNpZ25hbCBzdG9wcyAoRVhDX1NPRlRfU0lHTkFMKSBmb3J3YXJkIHRoZSBPUklHSU5BTCBzaWdubwovLyBmcm9tIG1lZGF0YVsxXSBhbmQgYXJlIG5ldmVyIGd1YXJkZWQ7IHJhdyBmYXVsdCBzdG9wcyBmb3J3YXJkIGEgbWFwcGVkCi8vIHNpZ25hbCB3aXRoIGEga2lsbC1ub3QtZGV0YWNoIGxhc3QgcmVzb3J0IChkZXRhY2ggbGVhdmVzIHRoZSB0YXNrIHBvcnQKLy8gcmVnaXN0ZXJlZCBidXQgdW5zZXJ2aWNlZCAtPiBwYXJrZWQgdGhyZWFkcykuCi8vIG1sMzQ1OiBvbmx5IGdlbnVpbmUgQlJLIGluc3RydWN0aW9ucyBhcmUgc2tpcHBlZCAocGMrNCkuIFRoZSBkZWJ1Z2dlciBob2xkcwovLyB0aGUgVEFTSy1sZXZlbCBleGNlcHRpb24gcG9ydCwgc28gZXZlcnkgZmF1bHQgdGhlIGFwcCdzIG93biBNYWNoIGhhbmRsZXIKLy8gZGVjbGluZXMgKEtFUk5fRkFJTFVSRSkgbGFuZHMgSEVSRSDigJQgdGhlIG9sZCAiQUxXQVlTIGFkdmFuY2UgUEMiIGJlaGF2aW9yCi8vIHNraXAtc3RlcHBlZCByZWFsIGNyYXNoZXMgaW5zdHJ1Y3Rpb24gYnkgaW5zdHJ1Y3Rpb24gKGFuZCB6ZXJvZWQgeDApLAovLyBzaWxlbnRseSBjb3JydXB0aW5nIHRocmVhZHMgdW50aWwgdGhleSB3YW5kZXJlZCBpbnRvIGRhdGEgKG1sMzQ0OiBhCi8vIDQsMDAwLWZhdWx0ICs0IHdhbGsgdGhyb3VnaCBzaGFyZWQtY2FjaGUgZGF0YSBlbmRpbmcgaW4gYSBib2d1cyBndWVzdAovLyBleGNlcHRpb24pLiBOb24tQlJLIHN0b3BzIGFyZSBub3cgaGFuZGVkIGJhY2sgdG8gdGhlIHByb2Nlc3MgYXMgYSB1bml4Ci8vIHNpZ25hbCBzbyB3aW5lJ3Mgc2lnYWN0aW9uIGhhbmRsZXJzIHJ1bjsgaWYgdGhlIHNpZ25hbCBjYW5ub3QgYmUgZGVsaXZlcmVkCi8vIHRoZSBzY3JpcHQgZGV0YWNoZXMgc28gdGhlIHByb2Nlc3MgZGllcyB2aXNpYmx5IGluc3RlYWQgb2Ygd2FuZGVyaW5nLgoKZnVuY3Rpb24gbGl0dGxlRW5kaWFuSGV4U3RyaW5nVG9OdW1iZXIoaGV4U3RyKSB7CiAgICBjb25zdCBieXRlcyA9IFtdOwogICAgZm9yIChsZXQgaSA9IDA7IGkgPCBoZXhTdHIubGVuZ3RoOyBpICs9IDIpIHsKICAgICAgICBieXRlcy5wdXNoKHBhcnNlSW50KGhleFN0ci5zdWJzdHIoaSwgMiksIDE2KSk7CiAgICB9CiAgICBsZXQgbnVtID0gMG47CiAgICBmb3IgKGxldCBpID0gNzsgaSA+PSAwOyBpLS0pIHsKICAgICAgICBudW0gPSAobnVtIDw8IDhuKSB8IEJpZ0ludChieXRlc1tpXSB8fCAwKTsKICAgIH0KICAgIHJldHVybiBudW07Cn0KCmZ1bmN0aW9uIG51bWJlclRvTGl0dGxlRW5kaWFuSGV4U3RyaW5nKG51bSkgewogICAgY29uc3QgYnl0ZXMgPSBbXTsKICAgIGZvciAobGV0IGkgPSAwOyBpIDwgODsgaSsrKSB7CiAgICAgICAgYnl0ZXMucHVzaChOdW1iZXIobnVtICYgMHhGRm4pKTsKICAgICAgICBudW0gPj49IDhuOwogICAgfQogICAgcmV0dXJuIGJ5dGVzLm1hcChiID0+IGIudG9TdHJpbmcoMTYpLnBhZFN0YXJ0KDIsICcwJykpLmpvaW4oJycpOwp9CgpmdW5jdGlvbiBsaXR0bGVFbmRpYW5IZXhUb1UzMihoZXhTdHIpIHsKICAgIHJldHVybiBwYXJzZUludChoZXhTdHIubWF0Y2goLy4uL2cpLnJldmVyc2UoKS5qb2luKCcnKSwgMTYpOwp9CgpmdW5jdGlvbiBleHRyYWN0QnJrSW1tZWRpYXRlKHUzMikgewogICAgcmV0dXJuICh1MzIgPj4gNSkgJiAweEZGRkY7Cn0KCmxldCBwaWQgPSBnZXRfcGlkKCk7CmxvZyhgTWFkZWlyYSBKSVQ6IHBpZCA9ICR7cGlkfWApOwpsZXQgYXR0YWNoUmVzcG9uc2UgPSBzZW5kX2NvbW1hbmQoYHZBdHRhY2g7JHtwaWQudG9TdHJpbmcoMTYpfWApOwpsb2coYE1hZGVpcmEgSklUOiBhdHRhY2hlZCA9ICR7YXR0YWNoUmVzcG9uc2V9YCk7CgovLyBtbDM1NTogU1RPUCBTRVJWSUNJTkcgQU5ZVEhJTkcgQlVUIEJSSy4KLy8KLy8gRXZlcnkgc2lnbmFsIGFuZCBmYXVsdCBzdG9wIGNvc3RzIHNldmVyYWwgc3luY2hyb25vdXMgcHJvdG9jb2wgcm91bmQtdHJpcHMKLy8gb24gU3Rpa0RlYnVnJ3Mgc2lkZS4gV2luZSBzaWduYWxzIGNvbnN0YW50bHkgKHRocmVhZCBzdXNwZW5kL3Jlc3VtZSksIHNvIHRoZQovLyB2MiBzY3JpcHQgYnVybmVkIDI3cyBDUFUgaW4gfjYwcyBhbmQgaU9TIGtpbGxlZCBTdGlrRGVidWcgaXRzZWxmIHdpdGggdGhlCi8vIHNjZW5lLXVwZGF0ZSB3YXRjaGRvZyAoMHg4QkFERjAwRCkg4oCUIHdoaWNoIHRvcmUgZG93biB0aGUgZGVidWcgc2Vzc2lvbiBhbmQKLy8gbGVmdCBNYWRlaXJhIHRvIGJlIFNJR0tJTExlZCB3aXRoIG5vIGNyYXNoIHJlcG9ydC4gVGhhdCBpcyB0aGUgImluc3RhbnQKLy8gdmFuaXNoLCBlbXB0eSBTdGlrRGVidWcgbG9nIiB0aGUgdXNlciBrZXB0IHNlZWluZy4KLy8KLy8gQm90aCBwYWNrZXRzIGJlbG93IGFyZSBiZXN0LWVmZm9ydDsgb24gYW4gb2xkZXIgc3R1YiB0aGV5IHNpbXBseSBmYWlsIGFuZAovLyB0aGUgZmF1bHQvc2lnbmFsIHBhdGhzIGZ1cnRoZXIgZG93biBzdGlsbCB3b3JrIGFzIGJlZm9yZS4KLy8gICBRU2V0SWdub3JlZEV4Y2VwdGlvbnMg4oCUIGRlYnVnc2VydmVyIHN0b3BzIGludGVyY2VwdGluZyB0aGVzZSBNYWNoCi8vICAgICBleGNlcHRpb25zLCBzbyB0aGV5IHJlYWNoIHRoZSBhcHAncyBPV04gaGFuZGxlcnMgKHdpbmUgcmVnaXN0ZXJzCi8vICAgICB0aHJlYWQtbGV2ZWwgcG9ydHMgZm9yIEJBRF9BQ0NFU1MrQkFEX0lOU1RSVUNUSU9OLCBhbmQgYW55dGhpbmcgaXQKLy8gICAgIGRlY2xpbmVzIGJlY29tZXMgYSBub3JtYWwgQlNEIHNpZ25hbCBpbnRvIHdpbmUncyBzaWdhY3Rpb24gaGFuZGxlcnMpLgovLyAgIFFQYXNzU2lnbmFscyDigJQgZGVsaXZlciBzaWduYWxzIHRvIHRoZSBpbmZlcmlvciB3aXRob3V0IHN0b3BwaW5nLiBTSUdUUkFQCi8vICAgICBpcyBkZWxpYmVyYXRlbHkgRVhDTFVERUQ6IEJSSyBhcnJpdmVzIHRoYXQgd2F5IGFuZCBpcyBvdXIgd2hvbGUgam9iLgp7CiAgICBsZXQgaWduID0gc2VuZF9jb21tYW5kKGBRU2V0SWdub3JlZEV4Y2VwdGlvbnM6RVhDX0JBRF9BQ0NFU1M7RVhDX0JBRF9JTlNUUlVDVElPTmApOwogICAgbG9nKGBNYWRlaXJhIEpJVDogUVNldElnbm9yZWRFeGNlcHRpb25zIC0+ICR7aWduIHx8ICcodW5zdXBwb3J0ZWQpJ31gKTsKICAgIGxldCBzaWdzID0gW107CiAgICBmb3IgKGxldCBzID0gMTsgcyA8PSAzMTsgcysrKSBpZiAocyAhPT0gNSkgc2lncy5wdXNoKHMudG9TdHJpbmcoMTYpKTsKICAgIGxldCBwYXNzID0gc2VuZF9jb21tYW5kKGBRUGFzc1NpZ25hbHM6JHtzaWdzLmpvaW4oJzsnKX1gKTsKICAgIGxvZyhgTWFkZWlyYSBKSVQ6IFFQYXNzU2lnbmFscyAtPiAke3Bhc3MgfHwgJyh1bnN1cHBvcnRlZCknfWApOwp9CgpsZXQgZGV0YWNoZWQgPSBmYWxzZTsKbGV0IHByb3RvY29sRmFpbHVyZXMgPSAwOyAgLy8gY29uc2VjdXRpdmUgdW5wYXJzZWFibGUgcmVwbGllcyB0byBhIGNvbnRpbnVlCmxldCBwZW5kaW5nID0gbnVsbDsgICAgICAgIC8vIHN0b3AgcGFja2V0IHJldHVybmVkIGJ5IGEgY29udGludWUgd2UgYWxyZWFkeSBzZW50CmxldCBsYXN0RmF1bHRLZXkgPSBudWxsOyAgIC8vICJ0aWQ6cGMiIG9mIHRoZSBsYXN0IG5vbi1CUksgc3RvcApsZXQgZmF1bHRSZXBlYXRzID0gMDsKbGV0IGZhdWx0TG9ncyA9IDA7CmxldCBzaWdMb2dzID0gMDsKLy8gSGFyZCBjZWlsaW5nIG9uIFVJIGxvZyBsaW5lczogZWFjaCBsb2coKSBkcml2ZXMgYSBTd2lmdFVJIHVwZGF0ZSwgYW5kIGl0IGlzCi8vIHNjZW5lLXVwZGF0ZSBzdGFsbHMgdGhhdCB0aGUgd2F0Y2hkb2cga2lsbHMgZm9yLiBVc2UgdWxvZygpIGV2ZXJ5d2hlcmUKLy8gaW5zaWRlIHRoZSBzdG9wIGxvb3A7IGJhcmUgbG9nKCkgb25seSBmb3IgdGhlIGZldyBzdGFydHVwIGxpbmVzLgpsZXQgbG9nQnVkZ2V0ID0gNDA7CmZ1bmN0aW9uIHVsb2cobXNnKSB7IGlmIChsb2dCdWRnZXQgPiAwKSB7IGxvZ0J1ZGdldC0tOyBsb2cobXNnKTsgfSB9CgpmdW5jdGlvbiBsb29rc0xpa2VTdG9wKHJlc3ApIHsKICAgIHJldHVybiB0eXBlb2YgcmVzcCA9PT0gJ3N0cmluZycgJiYgL15bVFNXWF0vLnRlc3QocmVzcCk7Cn0KCi8vIFN0cmljdCBoZXggLT4gQmlnSW50LCBvciBudWxsIG9uIGFueXRoaW5nIGVsc2UuIEEgc3R1YiBhbnN3ZXJzIGEgZmFpbGVkIGBfTWAKLy8gd2l0aCBhbiBlcnJvciBzdHJpbmcsIGFuZCB0aGUgb2xkIGlubGluZSBgQmlnSW50KCcweCcgKyByZXBseSlgIHRocmV3IG9uCi8vIHRob3NlIOKAlCBhbiB1bmNhdWdodCB0aHJvdyBlbmRzIHRoZSB3aG9sZSBzY3JpcHQsIHdoaWNoIHRlYXJzIHRoZSBkZWJ1ZwovLyBzZXNzaW9uIChhbmQgSklUIHdpdGggaXQpIGRvd24gd2l0aCBubyBjcmFzaCByZXBvcnQuIE5vIHJlcGx5IG1heSB0aHJvdy4KZnVuY3Rpb24gcGFyc2VIZXhCaWdJbnQoc3RyKSB7CiAgICBpZiAodHlwZW9mIHN0ciAhPT0gJ3N0cmluZycpIHJldHVybiBudWxsOwogICAgbGV0IHMgPSBzdHIudHJpbSgpOwogICAgaWYgKHMuc3RhcnRzV2l0aCgnMHgnKSB8fCBzLnN0YXJ0c1dpdGgoJzBYJykpIHMgPSBzLnNsaWNlKDIpOwogICAgaWYgKCEvXlswLTlhLWZBLUZdKyQvLnRlc3QocykpIHJldHVybiBudWxsOwogICAgLy8gR0RCIGVycm9yIHJlcGxpZXMgYXJlICJFIE5OIiAoc29tZSBzdHVicyBkcm9wIHRoZSBzcGFjZSk6IHNob3J0IGFuZAogICAgLy8gRS1sZWFkaW5nLiBBbiBhZGRyZXNzIGlzIG5ldmVyIGVpdGhlci4gUmVqZWN0aW5nIHRoZXNlIGFsc28gc3RvcHMgdGhlCiAgICAvLyBvbGQgZmFpbHVyZSB3aGVyZSAiRTE0IiBiZWNhbWUgMHhFMTQgYW5kIHdhcyBoYW5kZWQgYmFjayBhcyBhIHBvb2wgYmFzZS4KICAgIGlmIChzLmxlbmd0aCA8IDYgfHwgKHMubGVuZ3RoIDw9IDQgJiYgL15bZUVdLy50ZXN0KHMpKSkgcmV0dXJuIG51bGw7CiAgICB0cnkgeyByZXR1cm4gQmlnSW50KCcweCcgKyBzKTsgfSBjYXRjaCAoZSkgeyByZXR1cm4gbnVsbDsgfQp9CgovLyBGYXRhbC1wYXRoIGxvZ2dpbmcgbXVzdCBzdXJ2aXZlIHRoZSB1bG9nIGJ1ZGdldDogd2hlbiB0aGUgYnVkZ2V0IGlzIHNwZW50IHdlCi8vIGFyZSB1c3VhbGx5IGluc2lkZSBleGFjdGx5IHRoZSBmYWlsdXJlIHRoaXMgbGluZSBleGlzdHMgdG8gcmV2ZWFsLgpmdW5jdGlvbiBlbG9nKG1zZykgeyBsb2cobXNnKTsgfQoKLy8gRm9yd2FyZCBhIHVuaXggc2lnbmFsIHRvIHRoZSBzdG9wcGVkIHRocmVhZCBhbmQgcmVtZW1iZXIgdGhlIG5leHQgc3RvcC4KLy8gUmV0dXJucyB0cnVlIGlmIHRoZSBjb250aW51ZSB3YXMgYWNjZXB0ZWQuCmZ1bmN0aW9uIGZvcndhcmRTaWduYWwoc2lnLCB0aWQpIHsKICAgIGxldCBzaWdIZXggPSBzaWcudG9TdHJpbmcoMTYpLnBhZFN0YXJ0KDIsICcwJyk7CiAgICBsZXQgcmVzcCA9IHNlbmRfY29tbWFuZChgdkNvbnQ7QyR7c2lnSGV4fToke3RpZH07Y2ApOwogICAgaWYgKCFsb29rc0xpa2VTdG9wKHJlc3ApKSB7CiAgICAgICAgcmVzcCA9IHNlbmRfY29tbWFuZChgQyR7c2lnSGV4fWApOwogICAgfQogICAgaWYgKGxvb2tzTGlrZVN0b3AocmVzcCkpIHsKICAgICAgICBwZW5kaW5nID0gcmVzcDsKICAgICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIHJldHVybiBmYWxzZTsKfQoKdHJ5IHsKICAgIHdoaWxlICghZGV0YWNoZWQpIHsKICAgICAgICBsZXQgYnJrUmVzcG9uc2UgPSBwZW5kaW5nICE9PSBudWxsID8gcGVuZGluZyA6IHNlbmRfY29tbWFuZChgY2ApOwogICAgICAgIHBlbmRpbmcgPSBudWxsOwoKICAgICAgICAvLyBXL1ggPSBpbmZlcmlvciBleGl0ZWQ7IG5vdGhpbmcgbGVmdCB0byBkZWJ1Zy4KICAgICAgICBpZiAodHlwZW9mIGJya1Jlc3BvbnNlID09PSAnc3RyaW5nJyAmJiAvXltXWF0vLnRlc3QoYnJrUmVzcG9uc2UpKSB7CiAgICAgICAgICAgIHVsb2coYE1hZGVpcmEgSklUOiBpbmZlcmlvciBleGl0ZWQgKCR7YnJrUmVzcG9uc2V9KWApOwogICAgICAgICAgICBkZXRhY2hlZCA9IHRydWU7CiAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgIH0KCiAgICAgICAgbGV0IHRpZE1hdGNoID0gL1RbMC05YS1mXSt0aHJlYWQ6KD88dGlkPlswLTlhLWZdKyk7Ly5leGVjKGJya1Jlc3BvbnNlKTsKICAgICAgICBsZXQgdGlkID0gdGlkTWF0Y2ggPyB0aWRNYXRjaC5ncm91cHNbJ3RpZCddIDogbnVsbDsKICAgICAgICBsZXQgcGNNYXRjaCA9IC8yMDooPzxyZWc+WzAtOWEtZl17MTZ9KTsvLmV4ZWMoYnJrUmVzcG9uc2UpOwogICAgICAgIGxldCBwYyA9IHBjTWF0Y2ggPyBwY01hdGNoLmdyb3Vwc1sncmVnJ10gOiBudWxsOwoKICAgICAgICBpZiAoIXRpZCB8fCAhcGMpIHsKICAgICAgICAgICAgLy8gQSByZXBseSB3ZSBjYW5ub3QgcGFyc2UgbWVhbnMgd2UgYXJlIHJlLWlzc3VpbmcgYGNgIGFnYWluc3QgYSB0YXJnZXQKICAgICAgICAgICAgLy8gdGhhdCBpcyBub3Qgc3RvcHBpbmcgZm9yIHVzLiBVbmJvdW5kZWQsIHRoYXQgaXMgYSBzeW5jaHJvbm91cwogICAgICAgICAgICAvLyByb3VuZC10cmlwIHN0b3JtIHRoYXQgcGVncyBTdGlrRGVidWcncyBDUFUgdW50aWwgdGhlIHNjZW5lLXVwZGF0ZQogICAgICAgICAgICAvLyB3YXRjaGRvZyBraWxscyBpdCAoMHg4QkFERjAwRCkgYW5kIHRlYXJzIHRoZSBzZXNzaW9uIOKAlCBhbmQgSklUIOKAlAogICAgICAgICAgICAvLyBkb3duIHdpdGggbm8gY3Jhc2ggcmVwb3J0LiBCb3VuZCBpdCBhbmQgZGV0YWNoIGNsZWFubHkgaW5zdGVhZCBzbwogICAgICAgICAgICAvLyB0aGUgYXBwJ3Mgb3duIEJSSy90cmFwIGhhbmRsZXJzIHRha2Ugb3ZlciBhbmQgdGhlIGZhaWx1cmUgaXMgdmlzaWJsZS4KICAgICAgICAgICAgcHJvdG9jb2xGYWlsdXJlcysrOwogICAgICAgICAgICBpZiAocHJvdG9jb2xGYWlsdXJlcyA+IDY0KSB7CiAgICAgICAgICAgICAgICBlbG9nKGBNYWRlaXJhIEpJVDogJHtwcm90b2NvbEZhaWx1cmVzfSB1bnBhcnNlYWJsZSByZXBsaWVzIOKAlCBkZXRhY2hpbmcgdG8gc3RvcCB0aGUgc3BpbmApOwogICAgICAgICAgICAgICAgc2VuZF9jb21tYW5kKGBEYCk7CiAgICAgICAgICAgICAgICBkZXRhY2hlZCA9IHRydWU7CiAgICAgICAgICAgICAgICBjb250aW51ZTsKICAgICAgICAgICAgfQogICAgICAgICAgICB1bG9nKGBNYWRlaXJhIEpJVDogZmFpbGVkIHRvIHBhcnNlICgke3Byb3RvY29sRmFpbHVyZXN9KSwgY29udGludWluZ2ApOwogICAgICAgICAgICBjb250aW51ZTsKICAgICAgICB9CiAgICAgICAgcHJvdG9jb2xGYWlsdXJlcyA9IDA7CgogICAgICAgIGxldCBwY051bSA9IGxpdHRsZUVuZGlhbkhleFN0cmluZ1RvTnVtYmVyKHBjKTsKCiAgICAgICAgLy8gbWVkYXRhIHZhbHVlcyBhcmUgaGV4IFdJVEhPVVQgMHggcHJlZml4IChtbDM0NSBydW46IEVYQ19TT0ZUX1NJR05BTAogICAgICAgIC8vIHByaW50ZWQgYXMgIjEwMDAzIikuIG1ldHlwZSBpcyBhIHNtYWxsIGludGVnZXIsIHNhbWUgZWl0aGVyIHdheS4KICAgICAgICBsZXQgbWV0eXBlTWF0Y2ggPSAvbWV0eXBlOihbMC05YS1mXSspOy8uZXhlYyhicmtSZXNwb25zZSk7CiAgICAgICAgbGV0IG1ldHlwZSA9IG1ldHlwZU1hdGNoID8gcGFyc2VJbnQobWV0eXBlTWF0Y2hbMV0sIDE2KSA6IDA7CiAgICAgICAgbGV0IG1lZGF0YSA9IFtdOwogICAgICAgIGxldCBtcmUgPSAvbWVkYXRhOihbMC05YS1meF0rKTsvZywgbW07CiAgICAgICAgd2hpbGUgKChtbSA9IG1yZS5leGVjKGJya1Jlc3BvbnNlKSkgIT09IG51bGwpIG1lZGF0YS5wdXNoKHBhcnNlSW50KG1tWzFdLCAxNikpOwoKICAgICAgICAvLyBFWENfU09GVFdBUkUgLyBFWENfU09GVF9TSUdOQUwgKG1ldHlwZSA1LCBtZWRhdGFbMF09MHgxMDAwMyk6IHRoZQogICAgICAgIC8vIGtlcm5lbCBpcyByb3V0aW5nIGEgdW5peCBTSUdOQUwgdGhyb3VnaCB0aGUgZGVidWdnZXIg4oCUIHB0aHJlYWRfa2lsbCwKICAgICAgICAvLyB3aW5lJ3Mgc3VzcGVuZCBzaWduYWxzLCBmYXVsdC1jb252ZXJzaW9uIHNpZ25hbHMsIGFsbCBvZiBpdC4gVGhpcyBpcwogICAgICAgIC8vIG5vdCBhIGZhdWx0IGFuZCBub3Qgb3VycyB0byBqdWRnZTogZm9yd2FyZCB0aGUgT1JJR0lOQUwgc2lnbm8KICAgICAgICAvLyAobWVkYXRhWzFdKSB1bnRvdWNoZWQsIG5ldmVyIGNvdW50IHJlcGVhdHMgKHdpbmUgbGVnaXRpbWF0ZWx5IHJldHJpZXMKICAgICAgICAvLyBzYW1lLXBjIGZhdWx0cyksIG5ldmVyIGRldGFjaC4gdjEgbWlzZGVsaXZlcmVkIHRoZXNlIGFzIFNJR1NFR1YgYW5kCiAgICAgICAgLy8gdGhlbiBkZXRhY2hlZCBvbiB3aW5lJ3MgYm9vdC10aW1lIHJldHJ5IGxvb3AgKG1sMzQ1KS4KICAgICAgICBpZiAobWV0eXBlID09PSA1KSB7CiAgICAgICAgICAgIGxldCBzaWdubyA9IChtZWRhdGEubGVuZ3RoID4gMSAmJiBtZWRhdGFbMV0gPj0gMSAmJiBtZWRhdGFbMV0gPD0gMzEpID8gbWVkYXRhWzFdIDogMDsKICAgICAgICAgICAgaWYgKHNpZ0xvZ3MgPCA4IHx8IChzaWdMb2dzICUgNTAwKSA9PT0gMCkgewogICAgICAgICAgICAgICAgdWxvZyhgTWFkZWlyYSBKSVQ6IHNvZnQtc2lnbmFsIHRpZD0ke3RpZH0gcGM9MHgke3BjTnVtLnRvU3RyaW5nKDE2KX0gYCArCiAgICAgICAgICAgICAgICAgICAgYHNpZ25vPSR7c2lnbm8gfHwgJz8nfSAoIyR7c2lnTG9nc30pYCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgc2lnTG9ncysrOwogICAgICAgICAgICBpZiAoc2lnbm8gPT09IDAgfHwgIWZvcndhcmRTaWduYWwoc2lnbm8sIHRpZCkpIHsKICAgICAgICAgICAgICAgIC8vIFVua25vd24gc2lnbm8gb3IgQyB1bnN1cHBvcnRlZDogcGxhaW4gY29udGludWUgYW5kIHRydXN0IHRoZQogICAgICAgICAgICAgICAgLy8gc3R1YiB0byBkZWxpdmVyIHRoZSBwZW5kaW5nIHNpZ25hbCBvbiByZXN1bWUuCiAgICAgICAgICAgICAgICBsZXQgcmVzcCA9IHNlbmRfY29tbWFuZChgY2ApOwogICAgICAgICAgICAgICAgaWYgKGxvb2tzTGlrZVN0b3AocmVzcCkpIHBlbmRpbmcgPSByZXNwOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgIH0KCiAgICAgICAgbGV0IGluc3RySGV4ID0gc2VuZF9jb21tYW5kKGBtJHtwY051bS50b1N0cmluZygxNil9LDRgKTsKICAgICAgICBsZXQgaW5zbk9rID0gdHlwZW9mIGluc3RySGV4ID09PSAnc3RyaW5nJyAmJiAvXlswLTlhLWZBLUZdezh9JC8udGVzdChpbnN0ckhleCk7CiAgICAgICAgbGV0IGluc3RyVTMyID0gaW5zbk9rID8gbGl0dGxlRW5kaWFuSGV4VG9VMzIoaW5zdHJIZXgpIDogMDsKICAgICAgICAvLyBCUksgI2ltbTE2ID0gMTEwMSAwMTAwIDAwMSBpbW0xNiAwMDAwMAogICAgICAgIGxldCBpc0JyayA9IGluc25PayAmJiAoKGluc3RyVTMyICYgMHhGRkUwMDAxRikgPj4+IDApID09PSAweEQ0MjAwMDAwOwoKICAgICAgICBpZiAoIWlzQnJrKSB7CiAgICAgICAgICAgIC8vIEEgcmF3IGZhdWx0IHN0b3AgZXNjYWxhdGVkIHBhc3QgdGhlIGFwcCdzIE1hY2ggaGFuZGxlci4gTmV2ZXIgc2tpcAogICAgICAgICAgICAvLyBpdC4gRGVsaXZlciBpdCBiYWNrIHRvIHRoZSBwcm9jZXNzIGFzIGEgdW5peCBzaWduYWwgc28gdGhlIGFwcCdzCiAgICAgICAgICAgIC8vIHNpZ2FjdGlvbiBoYW5kbGVycyAod2luZSBzZWd2L2J1cy9pbGwpIGdldCBhbiBob25lc3Qgc2hvdCBhdCBpdC4KICAgICAgICAgICAgbGV0IGtleSA9IGAke3RpZH06JHtwY31gOwogICAgICAgICAgICBmYXVsdFJlcGVhdHMgPSAoa2V5ID09PSBsYXN0RmF1bHRLZXkpID8gZmF1bHRSZXBlYXRzICsgMSA6IDE7CiAgICAgICAgICAgIGxhc3RGYXVsdEtleSA9IGtleTsKCiAgICAgICAgICAgIGxldCBrY29kZSA9IG1lZGF0YS5sZW5ndGggPiAwID8gbWVkYXRhWzBdIDogMDsKCiAgICAgICAgICAgIC8vIEVYQ19SRVNPVVJDRSAobWV0eXBlIDExKSBpcyBhIHRhc2stbGV2ZWwgYWR2aXNvcnksIG5vdCBhIHRocmVhZAogICAgICAgICAgICAvLyBmYXVsdCDigJQgTUVNT1JZL0hJR0hfV0FURVJNQVJLIGZpcmVzIHdoZW4gcGh5c19mb290cHJpbnQgY3Jvc3NlcwogICAgICAgICAgICAvLyB0aGUgamV0c2FtIGxpbWl0IChrY29kZSBiaXRzIDEyOjAgPSBsaW1pdCBpbiBNQjsgbWwzNTkgc2F3IDQwOTYpLgogICAgICAgICAgICAvLyBUaGUgb2xkIGRlZmF1bHQgaW5qZWN0ZWQgU0lHU0VHViBpbnRvIHdoYXRldmVyIHRocmVhZCB0aGUgc3RvcAogICAgICAgICAgICAvLyBuYW1lZCwgY3Jhc2hpbmcgYW4gaW5ub2NlbnQgdGhyZWFkIGF0IHRoZSB3b3JzdCBtb21lbnQuIExvZyBhbmQKICAgICAgICAgICAgLy8gcmVzdW1lIHdpdGggbm8gc2lnbmFsLgogICAgICAgICAgICBpZiAobWV0eXBlID09PSAxMSkgewogICAgICAgICAgICAgICAgdWxvZyhgTWFkZWlyYSBKSVQ6IEVYQ19SRVNPVVJDRSB0aWQ9JHt0aWR9IGtjb2RlPSR7a2NvZGUudG9TdHJpbmcoMTYpfSBgICsKICAgICAgICAgICAgICAgICAgICBgKG1lbW9yeSBIV00gJHtrY29kZSAmIDB4MWZmZn0gTUI/KSDigJQgY29udGludWluZywgbm8gc2lnbmFsYCk7CiAgICAgICAgICAgICAgICBsZXQgcmVzcCA9IHNlbmRfY29tbWFuZChgY2ApOwogICAgICAgICAgICAgICAgaWYgKGxvb2tzTGlrZVN0b3AocmVzcCkpIHBlbmRpbmcgPSByZXNwOwogICAgICAgICAgICAgICAgY29udGludWU7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIGxldCBzaWcgPSAxMTsgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgLy8gU0lHU0VHViBkZWZhdWx0CiAgICAgICAgICAgIGlmIChtZXR5cGUgPT09IDEpIHNpZyA9IChrY29kZSA9PT0gMSkgPyAxMSA6IDEwOyAvLyBCQURfQUNDRVNTOiBJTlZBTElE4oaSU0VHViwgUFJPVOKGkkJVUwogICAgICAgICAgICBlbHNlIGlmIChtZXR5cGUgPT09IDIpIHNpZyA9IDQ7ICAgICAgICAgICAgICAgIC8vIEJBRF9JTlNUUlVDVElPTiDihpIgU0lHSUxMCiAgICAgICAgICAgIGVsc2UgaWYgKG1ldHlwZSA9PT0gMykgc2lnID0gODsgICAgICAgICAgICAgICAgLy8gQVJJVEhNRVRJQyDihpIgU0lHRlBFCiAgICAgICAgICAgIGVsc2UgaWYgKG1ldHlwZSA9PT0gNikgc2lnID0gNTsgICAgICAgICAgICAgICAgLy8gQlJFQUtQT0lOVCAobm9uLUJSSykg4oaSIFNJR1RSQVAKCiAgICAgICAgICAgIGlmIChmYXVsdExvZ3MgPCAxNikgewogICAgICAgICAgICAgICAgZmF1bHRMb2dzKys7CiAgICAgICAgICAgICAgICB1bG9nKGBNYWRlaXJhIEpJVDogZmF1bHQgKG5vdCBCUkspIHRpZD0ke3RpZH0gcGM9MHgke3BjTnVtLnRvU3RyaW5nKDE2KX0gYCArCiAgICAgICAgICAgICAgICAgICAgYGluc249JHtpbnNuT2sgPyBpbnN0clUzMi50b1N0cmluZygxNikucGFkU3RhcnQoOCwgJzAnKSA6IGA8JHtpbnN0ckhleH0+YH0gYCArCiAgICAgICAgICAgICAgICAgICAgYG1ldHlwZT0ke21ldHlwZX0ga2NvZGU9JHtrY29kZS50b1N0cmluZygxNil9IC0+IHNpZyAke3NpZ30gKHJlcGVhdCAke2ZhdWx0UmVwZWF0c30pYCk7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIC8vIE5FVkVSIGRldGFjaCBoZXJlOiB3aXRoIHRoZSBTdGlrRGVidWcgd2luZG93IHN0aWxsIG9wZW4gdGhlIHRhc2sKICAgICAgICAgICAgLy8gZXhjZXB0aW9uIHBvcnQgc3RheXMgcmVnaXN0ZXJlZCBidXQgdW5zZXJ2aWNlZCwgYW5kIGV2ZXJ5IGxhdGVyCiAgICAgICAgICAgIC8vIGVzY2FsYXRlZCBmYXVsdCBwYXJrcyBpdHMgdGhyZWFkIGZvcmV2ZXIgKG1sMzQ1IHdlZGdlZCBzdGVhbS5leGUncwogICAgICAgICAgICAvLyBtYWluIHRocmVhZCBleGFjdGx5IHRoaXMgd2F5KS4gSWYgdGhlIGZhdWx0IHRydWx5IGNhbm5vdCBiZQogICAgICAgICAgICAvLyBkZWxpdmVyZWQsIGtpbGwgdGhlIGluZmVyaW9yIOKAlCBhIHZpc2libGUgZGVhdGggd2l0aCBsb2dzIGludGFjdC4KICAgICAgICAgICAgaWYgKGZhdWx0UmVwZWF0cyA+PSA4KSB7CiAgICAgICAgICAgICAgICB1bG9nKGBNYWRlaXJhIEpJVDogZmF1bHQgYXQgcGM9MHgke3BjTnVtLnRvU3RyaW5nKDE2KX0gdW5kZWxpdmVyYWJsZSBhZnRlciBgICsKICAgICAgICAgICAgICAgICAgICBgJHtmYXVsdFJlcGVhdHN9IHRyaWVzIOKAlCBraWxsaW5nIGluZmVyaW9yICh2aXNpYmxlIGRlYXRoIGJlYXRzIGEgcGFya2VkIHRocmVhZClgKTsKICAgICAgICAgICAgICAgIHNlbmRfY29tbWFuZChga2ApOwogICAgICAgICAgICAgICAgZGV0YWNoZWQgPSB0cnVlOwogICAgICAgICAgICAgICAgY29udGludWU7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIGlmICghZm9yd2FyZFNpZ25hbChzaWcsIHRpZCkpIHsKICAgICAgICAgICAgICAgIC8vIEZvcndhcmRpbmcgcmVqZWN0ZWQ6IHBsYWluIGNvbnRpbnVlOyBpZiB0aGUgc2FtZSBzdG9wIHJlY3VycwogICAgICAgICAgICAgICAgLy8gdGhlIGd1YXJkIGFib3ZlIGV2ZW50dWFsbHkga2lsbHMuCiAgICAgICAgICAgICAgICBsZXQgcmVzcCA9IHNlbmRfY29tbWFuZChgY2ApOwogICAgICAgICAgICAgICAgaWYgKGxvb2tzTGlrZVN0b3AocmVzcCkpIHBlbmRpbmcgPSByZXNwOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgIH0KCiAgICAgICAgLy8gR2VudWluZSBCUksgZnJvbSBoZXJlIG9uIOKAlCB0aGUgcHJvdG9jb2wgcGF0aC4KICAgICAgICBsYXN0RmF1bHRLZXkgPSBudWxsOwogICAgICAgIGZhdWx0UmVwZWF0cyA9IDA7CgogICAgICAgIGxldCBicmtJbW0gPSBleHRyYWN0QnJrSW1tZWRpYXRlKGluc3RyVTMyKTsKCiAgICAgICAgLy8gQWR2YW5jZSBQQyBwYXN0IHRoZSBCUksgc28gaXQgY2Fubm90IHJlLWZpcmUKICAgICAgICBsZXQgcGNQbHVzNCA9IG51bWJlclRvTGl0dGxlRW5kaWFuSGV4U3RyaW5nKHBjTnVtICsgNG4pOwogICAgICAgIHNlbmRfY29tbWFuZChgUDIwPSR7cGNQbHVzNH07dGhyZWFkOiR7dGlkfTtgKTsKCiAgICAgICAgbGV0IHgxNk1hdGNoID0gLzEwOig/PHJlZz5bMC05YS1mXXsxNn0pOy8uZXhlYyhicmtSZXNwb25zZSk7CiAgICAgICAgbGV0IHgxNiA9IHgxNk1hdGNoID8geDE2TWF0Y2guZ3JvdXBzWydyZWcnXSA6IG51bGw7CgogICAgICAgIC8vIFNraXAgdW5rbm93biBCUksgaW1tZWRpYXRlcyAoUEMgYWxyZWFkeSBhZHZhbmNlZCkKICAgICAgICBpZiAoKGJya0ltbSAhPT0gMHhmMDBkICYmIGJya0ltbSAhPT0gMHg2OSkgfHwgIXgxNikgewogICAgICAgICAgICAvLyBTZXQgeDA9MCAoZmFpbHVyZS9za2lwIGluZGljYXRvcikgc28gYXBwJ3MgU0lHVFJBUCBmYWxsYmFjayB3b3JrcwogICAgICAgICAgICBzZW5kX2NvbW1hbmQoYFAwPSR7bnVtYmVyVG9MaXR0bGVFbmRpYW5IZXhTdHJpbmcoMG4pfTt0aHJlYWQ6JHt0aWR9O2ApOwogICAgICAgICAgICBjb250aW51ZTsKICAgICAgICB9CgogICAgICAgIHVsb2coYE1hZGVpcmEgSklUOiBCUksgIzB4JHticmtJbW0udG9TdHJpbmcoMTYpfWApOwoKICAgICAgICAvLyBQYXJzZSB4MCBhbmQgeDEKICAgICAgICBsZXQgeDBNYXRjaCA9IC8wMDooPzxyZWc+WzAtOWEtZl17MTZ9KTsvLmV4ZWMoYnJrUmVzcG9uc2UpOwogICAgICAgIGxldCB4MU1hdGNoID0gLzAxOig/PHJlZz5bMC05YS1mXXsxNn0pOy8uZXhlYyhicmtSZXNwb25zZSk7CiAgICAgICAgbGV0IHgwID0geDBNYXRjaCA/IGxpdHRsZUVuZGlhbkhleFN0cmluZ1RvTnVtYmVyKHgwTWF0Y2guZ3JvdXBzWydyZWcnXSkgOiAwbjsKICAgICAgICBsZXQgeDEgPSB4MU1hdGNoID8gbGl0dGxlRW5kaWFuSGV4U3RyaW5nVG9OdW1iZXIoeDFNYXRjaC5ncm91cHNbJ3JlZyddKSA6IDBuOwogICAgICAgIGxldCB4MTZOdW0gPSBsaXR0bGVFbmRpYW5IZXhTdHJpbmdUb051bWJlcih4MTYpOwoKICAgICAgICBpZiAoYnJrSW1tID09PSAweGYwMGQpIHsKICAgICAgICAgICAgdWxvZyhgTWFkZWlyYSBKSVQ6IHgxNiA9ICR7eDE2TnVtfWApOwoKICAgICAgICAgICAgaWYgKHgxNk51bSA9PT0gMG4pIHsKICAgICAgICAgICAgICAgIC8vIENNRF9ERVRBQ0gKICAgICAgICAgICAgICAgIHVsb2coYE1hZGVpcmEgSklUOiBkZXRhY2hgKTsKICAgICAgICAgICAgICAgIHNlbmRfY29tbWFuZChgRGApOwogICAgICAgICAgICAgICAgZGV0YWNoZWQgPSB0cnVlOwoKICAgICAgICAgICAgfSBlbHNlIGlmICh4MTZOdW0gPT09IDFuKSB7CiAgICAgICAgICAgICAgICAvLyBDTURfUFJFUEFSRV9SRUdJT04KICAgICAgICAgICAgICAgIHVsb2coYE1hZGVpcmEgSklUOiBwcmVwYXJlIGFkZHI9MHgke3gwLnRvU3RyaW5nKDE2KX0gc2l6ZT0weCR7eDEudG9TdHJpbmcoMTYpfWApOwoKICAgICAgICAgICAgICAgIGxldCBhZGRyID0geDA7CiAgICAgICAgICAgICAgICBpZiAoeDAgPT09IDBuICYmIHgxICE9PSAwbikgewogICAgICAgICAgICAgICAgICAgIGxldCBhbGxvY1Jlc3AgPSBzZW5kX2NvbW1hbmQoYF9NJHt4MS50b1N0cmluZygxNil9LHJ4YCk7CiAgICAgICAgICAgICAgICAgICAgbGV0IHBhcnNlZCA9IHBhcnNlSGV4QmlnSW50KGFsbG9jUmVzcCk7CiAgICAgICAgICAgICAgICAgICAgaWYgKHBhcnNlZCAhPT0gbnVsbCAmJiBwYXJzZWQgIT09IDBuKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGFkZHIgPSBwYXJzZWQ7CiAgICAgICAgICAgICAgICAgICAgICAgIHVsb2coYE1hZGVpcmEgSklUOiBhbGxvY2F0ZWQgYXQgMHgke2FkZHIudG9TdHJpbmcoMTYpfWApOwogICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgICAgIC8vIE5ldmVyIGludmVudCBhbiBhZGRyZXNzIGZyb20gYW4gZXJyb3IgcmVwbHkg4oCUIHRoZSBvbGQKICAgICAgICAgICAgICAgICAgICAgICAgLy8gY29kZSB0dXJuZWQgdGhlIHN0dWIncyAiRTE0IiBpbnRvIGJhc2UgMHhFMTQgYW5kIGhhbmRlZAogICAgICAgICAgICAgICAgICAgICAgICAvLyBpdCBiYWNrIGFzIHRoZSBwb29sLCB3aGljaCB0aGUgYXBwIHRoZW4gZXhlY3V0ZWQgZnJvbS4KICAgICAgICAgICAgICAgICAgICAgICAgZWxvZyhgTWFkZWlyYSBKSVQ6IF9NJHt4MS50b1N0cmluZygxNil9LHJ4IGZhaWxlZCAocmVwbHk9JHthbGxvY1Jlc3B9KSDigJQgbm8gcG9vbGApOwogICAgICAgICAgICAgICAgICAgICAgICBhZGRyID0gMG47CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfQoKICAgICAgICAgICAgICAgIGlmIChhZGRyICE9PSAwbiAmJiB4MSAhPT0gMG4pIHsKICAgICAgICAgICAgICAgICAgICBsZXQgcHJlcFJlc3AgPSBwcmVwYXJlX21lbW9yeV9yZWdpb24oYWRkciwgeDEpOwogICAgICAgICAgICAgICAgICAgIHVsb2coYE1hZGVpcmEgSklUOiBwcmVwYXJlZCA9ICR7cHJlcFJlc3B9YCk7CiAgICAgICAgICAgICAgICB9CgogICAgICAgICAgICAgICAgc2VuZF9jb21tYW5kKGBQMD0ke251bWJlclRvTGl0dGxlRW5kaWFuSGV4U3RyaW5nKGFkZHIpfTt0aHJlYWQ6JHt0aWR9O2ApOwoKICAgICAgICAgICAgfSBlbHNlIGlmICh4MTZOdW0gPT09IDNuKSB7CiAgICAgICAgICAgICAgICAvLyBDTURfTUFQX1BBR0VfWkVSTzogTWFwIGEgcGFnZSBhdCBhZGRyZXNzIDAgd2l0aCBURUIgZGF0YS4KICAgICAgICAgICAgICAgIC8vIHgwID0gVEVCIGFkZHJlc3MsIHgxID0gc2l6ZSAoMHg0MDAwID0gMTZLQiBpT1MgcGFnZSkKICAgICAgICAgICAgICAgIC8vIFRoZSBhcHAgY2FuJ3QgbWFwIHBhZ2UgMCBpdHNlbGYgKGtlcm5lbCByZWZ1c2VzKS4gVGhlIGRlYnVnZ2VyCiAgICAgICAgICAgICAgICAvLyBtYXkgaGF2ZSBkaWZmZXJlbnQgcHJpdmlsZWdlcyB0byBjcmVhdGUgdGhpcyBtYXBwaW5nLgogICAgICAgICAgICAgICAgdWxvZyhgTWFkZWlyYSBKSVQ6IG1hcCBwYWdlIHplcm8sIFRFQj0weCR7eDAudG9TdHJpbmcoMTYpfSBzaXplPTB4JHt4MS50b1N0cmluZygxNil9YCk7CgogICAgICAgICAgICAgICAgbGV0IHN1Y2Nlc3MgPSAwbjsKCiAgICAgICAgICAgICAgICAvLyBUcnkgYWxsb2NhdGluZyBSVyBtZW1vcnkgYXQgYWRkcmVzcyAwIHZpYSBfTSB3aXRoIGZpeGVkIGFkZHJlc3MKICAgICAgICAgICAgICAgIC8vIFN0aWtEZWJ1ZydzIF9NIGNvbW1hbmQ6IF9NPHNpemU+LDxwZXJtcz4g4oCUIGJ1dCBkb2Vzbid0IHN1cHBvcnQgZml4ZWQgYWRkcgogICAgICAgICAgICAgICAgLy8gVHJ5IEdEQiBtZW1vcnkgYWxsb2NhdGlvbjogbW1hcCB2aWEgdGhlIGRlYnVnZ2VyJ3MgdGFzayBwb3J0CiAgICAgICAgICAgICAgICAvLyBVc2UgdkNvbnQgb3IgZGlyZWN0IE1hY2ggY2FsbHMgaWYgYXZhaWxhYmxlCgogICAgICAgICAgICAgICAgLy8gQXBwcm9hY2ggMTogVHJ5IHdyaXRpbmcgVEVCIGRhdGEgdG8gYWRkcmVzcyAwIGRpcmVjdGx5LgogICAgICAgICAgICAgICAgLy8gSWYgdGhlIGhhcmR3YXJlIHplcm8gcGFnZSBpcyB3cml0YWJsZSB2aWEgdGhlIGRlYnVnZ2VyLCB0aGlzIHdvcmtzLgogICAgICAgICAgICAgICAgaWYgKHgwICE9PSAwbiAmJiB4MSAhPT0gMG4pIHsKICAgICAgICAgICAgICAgICAgICAvLyBSZWFkIFRFQiBkYXRhIGZyb20gdGhlIGFwcCdzIG1lbW9yeQogICAgICAgICAgICAgICAgICAgIGxldCB0ZWJQYWdlID0geDAgJiB+MHgzRkZGbjsgIC8vIGFsaWduIHRvIDE2S0IgcGFnZQogICAgICAgICAgICAgICAgICAgIGxldCB0ZWJPZmYgPSB4MCAtIHRlYlBhZ2U7CgogICAgICAgICAgICAgICAgICAgIC8vIFRyeSB0byB3cml0ZSBURUIgZGF0YSBhdCBhZGRyZXNzIDAgdmlhIEdEQiBNIGNvbW1hbmQKICAgICAgICAgICAgICAgICAgICAvLyBSZWFkIDI1NiBieXRlcyBmcm9tIFRFQiAoZW5vdWdoIGZvciBQRUIgcG9pbnRlciBhdCBvZmZzZXQgMHg2MCkKICAgICAgICAgICAgICAgICAgICBsZXQgdGViRGF0YSA9IHNlbmRfY29tbWFuZChgbSR7eDAudG9TdHJpbmcoMTYpfSwxMDBgKTsKICAgICAgICAgICAgICAgICAgICBpZiAodGViRGF0YSAmJiB0ZWJEYXRhLmxlbmd0aCA+IDApIHsKICAgICAgICAgICAgICAgICAgICAgICAgLy8gV3JpdGUgaXQgdG8gYWRkcmVzcyAwK3RlYk9mZgogICAgICAgICAgICAgICAgICAgICAgICBsZXQgd3JpdGVSZXNwID0gc2VuZF9jb21tYW5kKGBNJHt0ZWJPZmYudG9TdHJpbmcoMTYpfSwkeyh0ZWJEYXRhLmxlbmd0aC8yKS50b1N0cmluZygxNil9OiR7dGViRGF0YX1gKTsKICAgICAgICAgICAgICAgICAgICAgICAgdWxvZyhgTWFkZWlyYSBKSVQ6IHdyaXRlIFRFQiB0byBwYWdlMCBvZmZzZXQgMHgke3RlYk9mZi50b1N0cmluZygxNil9OiAke3dyaXRlUmVzcH1gKTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHdyaXRlUmVzcCA9PT0gJ09LJykgewogICAgICAgICAgICAgICAgICAgICAgICAgICAgc3VjY2VzcyA9IDFuOwogICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfQoKICAgICAgICAgICAgICAgIHNlbmRfY29tbWFuZChgUDA9JHtudW1iZXJUb0xpdHRsZUVuZGlhbkhleFN0cmluZyhzdWNjZXNzKX07dGhyZWFkOiR7dGlkfTtgKTsKICAgICAgICAgICAgfQoKICAgICAgICB9IGVsc2UgaWYgKGJya0ltbSA9PT0gMHg2OSkgewogICAgICAgICAgICAvLyBMZWdhY3kgcHJvdG9jb2wKICAgICAgICAgICAgdWxvZyhgTWFkZWlyYSBKSVQ6IGxlZ2FjeSBCUksgMHg2OSwgeDA9MHgke3gwLnRvU3RyaW5nKDE2KX1gKTsKICAgICAgICAgICAgaWYgKHgwICE9PSAwbikgewogICAgICAgICAgICAgICAgcHJlcGFyZV9tZW1vcnlfcmVnaW9uKHgwLCB4MCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgc2VuZF9jb21tYW5kKGBQMD0ke251bWJlclRvTGl0dGxlRW5kaWFuSGV4U3RyaW5nKHgwKX07dGhyZWFkOiR7dGlkfTtgKTsKICAgICAgICB9CiAgICB9Cn0gY2F0Y2ggKGUpIHsKICAgIC8vIEFueSBleGNlcHRpb24gaW4gdGhlIHN0b3AgbG9vcCB3b3VsZCBvdGhlcndpc2UgZW5kIHRoZSBzY3JpcHQsIHdoaWNoCiAgICAvLyBTdGlrRGVidWcgdHJlYXRzIGFzIHRoZSBzZXNzaW9uIGVuZGluZzogSklUIGRpc2FwcGVhcnMgd2l0aCBubyBjcmFzaAogICAgLy8gcmVwb3J0LiBEZXRhY2ggZGVsaWJlcmF0ZWx5IGluc3RlYWQgc28gdGhlIGFwcCdzIG93biBoYW5kbGVycyB0YWtlCiAgICAvLyBvdmVyIGFuZCB0aGUgcmVhc29uIGlzIGluIHRoZSBsb2cuCiAgICBsb2coYE1hZGVpcmEgSklUOiBzdG9wIGxvb3AgYWJvcnRlZDogJHtlfSDigJQgZGV0YWNoaW5nYCk7CiAgICB0cnkgeyBzZW5kX2NvbW1hbmQoYERgKTsgfSBjYXRjaCAoZTIpIHsgfQogICAgZGV0YWNoZWQgPSB0cnVlOwp9Cg=="

    /// Load script from madeira-jit.js file next to the binary (development convenience).
    /// Falls back to the embedded base64 above for release builds.
    private static var resolvedScriptBase64: String {
        // Try loading from bundle first (if added to Copy Bundle Resources)
        if let url = Bundle.main.url(forResource: "madeira-jit", withExtension: "js"),
           let data = try? Data(contentsOf: url) {
            return data.base64EncodedString()
        }
        return scriptBase64
    }

    /// Check if StikDebug or StikJIT is available by trying to open their URL.
    static var isAvailable: Bool {
        guard let url = URL(string: "stikjit://enable-jit") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Open StikDebug with our JIT script embedded in the URL.
    /// StikDebug will attach to our process and run the script.
    static func enableJIT(completion: @escaping (Bool) -> Void) {
        // A fresh attach is being requested. CS_DEBUGGED is sticky across
        // detach, so "Enable JIT" can legitimately be pressed again to
        // re-attach — allow the next detachDebugger() to act.
        resetDetachState()

        let bundleId = Bundle.main.bundleIdentifier ?? "com.madeira.emulator"

        // Build the URL with script data
        let scriptData = resolvedScriptBase64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "stikjit://enable-jit?bundle-id=\(bundleId)&script-data=\(scriptData)"

        guard let url = URL(string: urlString) else {
            LogStore.shared.log("Failed to build StikJIT URL", level: .error)
            completion(false)
            return
        }

        LogStore.shared.log("Opening StikDebug to enable JIT...")

        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                LogStore.shared.log("Failed to open StikDebug. Is it installed?", level: .error)
                completion(false)
                return
            }

            // Poll for CS_DEBUGGED flag
            pollForJIT(completion: completion)
        }
    }

    /// Poll every 0.5s until CS_DEBUGGED is set, then call completion.
    private static func pollForJIT(completion: @escaping (Bool) -> Void) {
        // Bounded: if StikDebug never attaches (user dismissed the prompt, the
        // script failed to vAttach, or StikDebug's scene-update watchdog killed
        // it), the poll would otherwise fire forever and the caller would wait
        // on a completion that never arrives — a silent hang, not an error.
        // The caller already renders completion(false) as .unavailable.
        var ticks = 0
        let maxTicks = 60  // 30s, well past every observed attach
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            if jit_check_debugged() {
                timer.invalidate()
                LogStore.shared.log("JIT enabled! (CS_DEBUGGED set)", level: .success)
                completion(true)
                return
            }
            ticks += 1
            if ticks >= maxTicks {
                timer.invalidate()
                LogStore.shared.log("JIT enable timed out after \(maxTicks / 2)s: "
                    + "StikDebug never set CS_DEBUGGED (not installed, unable to "
                    + "attach, or its script failed).", level: .error)
                completion(false)
            }
        }
    }

    /// Allocate a JIT memory pool via BRK #0xf00d, then detach the debugger.
    /// Call this after CS_DEBUGGED is confirmed.
    /// Returns the allocated RX base address and RW mapping, or nil on failure.
    static func allocateAndDetach(poolSize: Int = 128 * 1024 * 1024) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
        guard let result = allocatePool(poolSize: poolSize) else { return nil }
        // Don't detach yet — Wine needs the debugger to prepare PE DLL code pages.
        // Detach will happen later via detachDebugger().
        return result
    }

    /// Allocate a JIT memory pool via BRK #0xf00d WITHOUT detaching the debugger.
    /// The debugger stays attached so Wine can use BRK to prepare PE code pages.
    static func allocatePool(poolSize requestedSize: Int = 128 * 1024 * 1024) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
        // ml793: the pool the caller asks for and the pool the address space can
        // hold are two different numbers. Everything downstream (RW alias, the
        // no-footprint ledger, WINE_IOS_JIT_SIZE) must agree on the one that was
        // actually allocated, so the request is a value and this is the name the
        // rest of the function uses.
        var poolSize = requestedSize
        LogStore.shared.log("Allocating \(requestedSize / 1024 / 1024)MB JIT pool via debugger...")

        // iOS-Madeira: FEX's dispatcher emit has a position-dependent encoding
        // bug — only works when the JIT pool lands at a high enough address
        // (empirically ≥ 0x119000000, so dispatcher at +0x7ffc130 has top byte
        // 0x12). When iOS allocates 0x114-0x117xxx the dispatcher's literal-
        // pool fixups silently break and execution branches to zero memory
        // before the first compiled block runs. Pre-claim ~96MB of low address
        // space to push the next ANYWHERE allocation up.
        //
        // We keep these allocations alive for the lifetime of the process —
        // freeing them could let iOS reuse them and cause aliasing issues.
        var pinChunks: [vm_address_t] = []
        let chunkSize = 16 * 1024 * 1024  // 16 MB per chunk
        // Pin until the allocation frontier crosses the mode-A threshold
        // (0x119000000) instead of a fixed 96MB. A fixed count loses the
        // ASLR lottery whenever the base slide is low (observed 2026-07-03:
        // 6 chunks ended at 0x118790000, pool landed 8.4MB short of the
        // threshold and the run fast-failed). vm_allocate is zero-fill
        // reserve-only, so extra chunks don't add resident footprint.
        // The BAD POOL check below stays as the safety net for non-
        // sequential placements.
        let pinTarget: vm_address_t = 0x119000000
        let maxChunks = 32                 // safety cap (512 MB of reservation)
        for i in 0..<maxChunks {
            var addr: vm_address_t = 0
            let kr = vm_allocate(mach_task_self_, &addr, vm_size_t(chunkSize), VM_FLAGS_ANYWHERE)
            if kr == KERN_SUCCESS {
                pinChunks.append(addr)
                LogStore.shared.log(String(format: "JIT-pool pin chunk %d at 0x%lx (16MB)", i, Int(addr)))
                if addr + vm_address_t(chunkSize) >= pinTarget { break }
            } else {
                LogStore.shared.log("JIT-pool pin chunk \(i) FAILED kr=\(kr)", level: .error)
                break
            }
        }

        // ml793: reserve-and-carve, the fix ml596 said was needed but did not
        // have. Pinning only walks the frontier; it never guarantees the hole
        // the pool needs exists at the new frontier. That is exactly what breaks
        // a 1760MB pool: a 7GB device derives 1760MB from recommendedPoolMB(),
        // the low region between the app's mappings and the GPU carveout holds
        // roughly a gigabyte of contiguous space, so no first fit exists below
        // 448G and the kernel hands back the guest window instead. ml595 was
        // this same failure at 896MB: three identical 0x7000000000 placements,
        // then abort, every launch.
        //
        // So measure the hole instead of assuming it. Grow a contiguous
        // reservation at the frontier until it covers the request or until a
        // chunk lands in the guest window (which proves the low region is out),
        // release the run, and ask the debugger for exactly the size it proved.
        // The kernel's first fit then has nowhere else to go, the pool is as
        // large as the address space allows, and it never lands in the guest
        // window. Probed chunks are freed in every branch, so the cost is VA
        // churn, not footprint.
        let goodLow = 0x119000000
        let guestLo = 0x7000000000
        let guestHi = 0x8000000000

        func inGuestWindow(_ a: Int, _ size: Int) -> Bool {
            a + size > guestLo && a < guestHi
        }

        /// Release and return the largest contiguous hole at the current
        /// frontier, capped at `limit`. Returns (0, 0) when nothing usable below
        /// the guest window is left.
        func carveHole(limit: Int) -> (base: vm_address_t, size: Int) {
            var start: vm_address_t = 0
            var end: vm_address_t = 0
            let cap = min(limit, 4096 * 1024 * 1024)
            while Int(end - start) < cap {
                var addr: vm_address_t = 0
                guard vm_allocate(mach_task_self_, &addr, vm_size_t(chunkSize), VM_FLAGS_ANYWHERE) == KERN_SUCCESS else { break }
                let next = addr + vm_address_t(chunkSize)
                // A chunk at or past the guest window means the low region is
                // exhausted; a non-adjacent chunk means the run stopped being a
                // single hole. Either way, keep what was measured and stop.
                if Int(next) > guestLo || (start != 0 && addr != end) {
                    vm_deallocate(mach_task_self_, addr, vm_size_t(chunkSize))
                    break
                }
                if start == 0 { start = addr }
                end = next
            }
            guard start != 0, end > start else { return (0, 0) }
            let size = Int(end - start)
            // Log BEFORE the release. The formatted line allocates, and malloc's
            // next region would be this hole — which is the one thing the pool
            // needs. Release is the last thing that happens here, so the
            // debugger's allocation is the next access to the address space.
            LogStore.shared.log(String(format: "Carve: %dMB hole at 0x%lx — releasing for the pool",
                                       size / 1024 / 1024, Int(start)))
            let kr = vm_deallocate(mach_task_self_, start, vm_size_t(size))
            guard kr == KERN_SUCCESS else { return (0, 0) }
            return (start, size)
        }

        // Below this a pool is not worth having: FEX would spend most of the run
        // recompiling evicted blocks. 256MB still covers a desktop session.
        let floorSize = 256 * 1024 * 1024

        /// One ask, one verdict. Kept as a closure so a wave can repeat the whole
        /// measure-then-ask sequence without duplicating the rejection test.
        func attemptPlacement(size: Int) -> UnsafeMutableRawPointer? {
            guard let p = jit26_prepare_region(nil, size),
                  p != UnsafeMutableRawPointer(bitPattern: 0) else {
                LogStore.shared.log("Debugger failed to allocate RX memory", level: .error)
                return nil
            }
            let a = Int(bitPattern: p)
            if a >= goodLow && !inGuestWindow(a, size) { return p }
            let why = a < goodLow ? "below the mode-A floor" : "in the guest 64G window"
            LogStore.shared.log(String(format: "BAD POOL placement 0x%lx (%@)", a, why),
                                level: .error)
            let dkr = vm_deallocate(mach_task_self_, vm_address_t(a), vm_size_t(size))
            LogStore.shared.log(dkr == KERN_SUCCESS
                ? "  bad region freed"
                : "  bad region kept as pin (vm_deallocate kr=\(dkr))")
            return nil
        }

        // ml794: waves, not one shot, and never a self-inflicted exit.
        //
        // ml595 measured what the old loop actually did: three asks at the same
        // size, in the same instant, with the same free-hole layout, so the kernel
        // answered 0x7000000000 three times and the run was abandoned. Two things
        // change that. The request now shrinks after each failed wave, because a
        // pool too large for the hole is the failure being hit; and the waves are
        // separated by a pause, because the layout is not static — a run that
        // cannot place a pool now can place one a moment later once transient
        // mappings drain. Only if every size down to the floor fails at the floor
        // is there genuinely no room, and even then this returns nil rather than
        // killing the process: the caller reports it and the user can press the
        // launch button again, which is a recoverable state instead of an app that
        // closes itself.
        var rxPtrOpt: UnsafeMutableRawPointer? = nil
        var measuredHole = 0
        var smallestTried = requestedSize
        // Largest first: the full request is what FEX wants, and every step down
        // costs translation-cache headroom. The list always ends at the floor so
        // a device that cannot fit anything larger still gets a usable pool.
        let candidates = [requestedSize, requestedSize / 2, requestedSize / 4, floorSize]
            .map { max($0 / chunkSize * chunkSize, floorSize) }
        for (wave, size) in candidates.enumerated() {
            smallestTried = size
            let hole = carveHole(limit: size)
            measuredHole = max(measuredHole, hole.size)
            if hole.base != 0, hole.size >= floorSize {
                // Never ask for more than the hole: a larger request would miss it
                // and fall back to the guest window.
                poolSize = min(size, hole.size / chunkSize * chunkSize)
                if let placed = attemptPlacement(size: poolSize) {
                    rxPtrOpt = placed
                    break
                }
            } else {
                LogStore.shared.log(String(format: "Carve: only %dMB below the guest window at %dMB requested",
                                           hole.size / 1024 / 1024, size / 1024 / 1024), level: .error)
            }
            if wave < candidates.count - 1 { Thread.sleep(forTimeInterval: 0.4) }
        }
        guard let rxPtr = rxPtrOpt else {
            LogStore.shared.log(String(format: "BAD POOL: no placement below the guest window "
                                       + "(largest hole %dMB, smallest request tried %dMB) — not starting Wine",
                                       measuredHole / 1024 / 1024, smallestTried / 1024 / 1024),
                                level: .error)
            LogStore.shared.log("  Press launch again, or lower the JIT pool in Settings.", level: .info)
            return nil
        }
        let rxAddr = Int(bitPattern: rxPtr)
        LogStore.shared.log("RX pool at \(String(format: "%p", rxAddr)) (\(poolSize / 1024 / 1024)MB)")

        // Create RW mapping via vm_remap
        var rwAddr: vm_address_t = 0
        var curProt: vm_prot_t = 0
        var maxProt: vm_prot_t = 0

        // task #35: place the RW alias BELOW the 64GB carveout floor.
        // With VM_FLAGS_ANYWHERE the kernel picks the first free address above
        // the GPU carveout [64G,448G) — which is 0x7000000000 exactly. That is
        // the base of a 16GB jumbo slot, so this 896MB data-only mapping was
        // sterilizing a whole slot that CEF's PartitionAlloc needs. The top
        // window [448G,512G) holds only four such slots and CEF wants at least
        // four pools, so we cannot afford to spend one on ourselves.
        // Data-only (never executed — exec always goes through the RX alias),
        // so placement is unconstrained; fall back to ANYWHERE if all candidates
        // are taken, which restores the previous behaviour exactly.
        // ml91: six hand-picked candidates (8/12/16/24/32/48G) ALL failed —
        // sub-64G is far more crowded than assumed. Sweep the whole region on a
        // 1GB stride instead of guessing. Each failed vm_remap(FIXED) is cheap,
        // so ~58 probes at startup costs nothing and finds any real hole.
        // ml92 measured the real map: there is NO sub-64G space at all. The only
        // "free" region down there (0..0x102454000) is __PAGEZERO, and 4G-64G is
        // fully reserved (malloc xzone) — 58 probes on a 1GB stride found nothing.
        // Usable VA is exactly one ~63GB window, 0x7038000000..0x7fffdf0000.
        //
        // That window holds four 16GB-aligned slots (448/464/480/496G) and CEF's
        // PartitionAlloc wants one pool per slot. Landing here at 0x7000000000
        // spends the 448G slot on an 896MB mapping. Slot 496G is ALREADY ruined
        // by Wine furniture (PE images at ~0x7e874c0000 = 505.8G), so parking at
        // the very top costs nothing that isn't already lost and hands 448G back
        // to PartitionAlloc intact.
        // ml91/ml92/ml93: relocating this alias was tried and REVERTED. The map
        // says usable VA is a single ~63GB window (0x7038000000..0x7fffdf0000);
        // sub-64G is __PAGEZERO plus a fully-reserved 4G-64G band, so 58 probes
        // on a 1GB stride found nothing (ml92). Parking at the top of space
        // instead (0x7fc8000000) DID place, but Wine allocates its furniture
        // top-down — the TEB landed 1.25MB below us at 0x7fc7ec0000, pool copies
        // came out zero-filled, and libarm64ecfex died on 8 exec faults before
        // CEF was even reached (ml93). There is nowhere to put an 896MB mapping
        // that does not cost either a 16GB PartitionAlloc slot or Wine's own
        // furniture. The kernel pick (0x7000000000, base of the window) is the
        // least harmful: it spends the 448G slot but leaves the top — where Wine
        // clusters — alone.
        // ml96 census: CEF needs THREE 16GB pools (48GB), not the 144GB a naive
        // sum suggested — #3/#4/#5 are one pool re-rolling its hint, and the two
        // 32GB requests are that same pool over-reserving for 16GB ALIGNMENT.
        // 48GB fits in the 63GB window, so the third pool fails only because no
        // 16GB-ALIGNED slot is left: 464G and 480G are taken, 496G is broken by
        // Wine furniture, and 448G is spent on this 896MB alias.
        //
        // Freeing 448G should let pool 3 land. ml93 tried that and failed by
        // parking at 0x7fc8000000 — the extreme top, exactly where Wine
        // allocates its furniture top-down (the TEB landed 1.25MB below us and
        // pool copies came back zeroed). The map says 0x7c00000000..0x7e874c0000
        // is free, so take the BOTTOM of the already-broken 496G slot instead
        // and leave the top for Wine.
        // DO NOT relocate this alias without new evidence. Three placements were
        // measured against the default kernel pick (0x7000000000, which the
        // kernel picks because it is the first free address above the GPU
        // carveout):
        //   0x7000000000 (default)  ml94=8, ml96=1  exec faults, reaches libcef
        //   0x7fc8000000 (top)      ml93=8          exec faults, dies before CEF
        //   0x7c00000000 (496G)     ml97=16, ml98=16 exec faults, dies before CEF
        // Same fault class in every case (pool page loses content/exec, on a
        // recycled range) — relocation makes an EXISTING intermittent bug worse
        // rather than introducing a new one. Two mechanisms were proposed and
        // BOTH disproven: Wine furniture collision (ml93) and the reclaim-recover
        // band claiming the alias (ml97; the band exclusion landed in
        // signal_arm64_ios.c and did NOT change the count). Whatever couples the
        // alias base to pool stability is still unidentified.
        //
        // Cost of staying here: the alias occupies the base of the 448G slot, so
        // PartitionAlloc gets only two of the three 16GB-aligned pools it needs
        // (see the ml96 [jumbo#N] census). Freeing that slot is worth doing —
        // but by moving WINE's furniture out of 496G, not by moving this.
        rwAddr = 0
        let kr1 = vm_remap(
            mach_task_self_,
            &rwAddr,
            vm_size_t(poolSize),
            0,
            VM_FLAGS_ANYWHERE,
            mach_task_self_,
            vm_address_t(bitPattern: rxPtr),
            0, // copy = false
            &curProt,
            &maxProt,
            VM_INHERIT_NONE
        )

        guard kr1 == KERN_SUCCESS else {
            LogStore.shared.log("vm_remap failed: \(kr1)", level: .error)
            return nil
        }

        // Set RW protection
        let kr2 = vm_protect(mach_task_self_, rwAddr, vm_size_t(poolSize), 0, VM_PROT_READ | VM_PROT_WRITE)
        guard kr2 == KERN_SUCCESS else {
            LogStore.shared.log("vm_protect(RW) failed: \(kr2)", level: .error)
            vm_deallocate(mach_task_self_, rwAddr, vm_size_t(poolSize))
            return nil
        }

        let rwPtr = UnsafeMutableRawPointer(bitPattern: rwAddr)!
        LogStore.shared.log("RW mapping at \(String(format: "%p", Int(bitPattern: rwPtr)))")

        // ml358: the pool has NEVER been jetsam-exempt. jit_region_create()
        // applies NO_FOOTPRINT, but this path takes its RX pages from the
        // debugger and vm_remaps the RW alias, so every written pool page has
        // counted against phys_footprint in full — which is what killed ml357
        // ("Terminated due to memory issue" with 848MB of pool written). Apply
        // the ledger exemption to the shared object now that both aliases
        // exist; the helper logs footprint either side, so the next log says
        // whether the kernel honoured it. Non-fatal if refused.
        // ml360: the entry must be made over the RW ALIAS, not the RX view —
        // ml360's run showed mach_make_memory_entry_64(READ|WRITE) over the
        // debugger's RX pages fails with KERN_PROTECTION_FAILURE. Same vm
        // object either way; the RW alias actually permits the access.
        let exempt = jit_make_region_no_footprint(rwPtr, poolSize, "pool-RW-alias")
        // ml359: log the verdict through LogStore.log (which appends to the
        // file) — the ml358 run lost it because the jit_log callback only fed
        // the UI view. Detail (kr / footprint delta) is in the jit_log lines.
        LogStore.shared.log("[no-footprint] pool applied=\(exempt)", level: exempt ? .success : .error)

        LogStore.shared.log("JIT pool ready (debugger still attached).", level: .success)

        return (rx: rxPtr, rw: rwPtr, size: poolSize)
    }

    /// Detach the debugger. Call this after Wine is done loading PE DLLs.
    ///
    /// Idempotent, and it has to be: the early-detach path detaches right after
    /// the pool is ready, and the post-Wine path detaches again unconditionally.
    /// By the second call the debugger is gone, so `jit26_detach()`'s BRK #0xf00d
    /// no longer reaches StikDebug — it lands in our own task-level exception
    /// port (ml522/ml523) as a spurious breakpoint after Wine has already exited,
    /// which is exactly the kind of stray fault the fallback handler has to guess
    /// at. The first detach wins; later calls are logged and dropped.
    private static var didDetach = false
    private static let detachLock = NSLock()

    /// Re-arm detachDebugger() for a new attach. Called from enableJIT().
    /// (Deliberately not a permanent C-level one-shot: JITAllocator.c cannot
    /// tell a re-attach from a duplicate call, and a sticky flag there would
    /// silently refuse to detach the second session.)
    private static func resetDetachState() {
        detachLock.lock()
        didDetach = false
        detachLock.unlock()
    }

    static func detachDebugger() {
        detachLock.lock()
        if didDetach {
            detachLock.unlock()
            LogStore.shared.log("Debugger already detached; ignoring duplicate request.")
            return
        }
        didDetach = true
        detachLock.unlock()

        LogStore.shared.log("Detaching debugger...")
        jit26_detach()
        // task #34: signal in-process waiters (share-probe poller). CS_DEBUGGED
        // is sticky post-detach, so an env flag is the reliable signal.
        setenv("MADEIRA_DETACHED", "1", 1)
        LogStore.shared.log("Debugger detached.", level: .success)
    }
}
