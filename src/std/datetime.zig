// Inspirsed by: https://github.com/frmdstryr/zig-datetime/blob/master/src/datetime.zig
pub const Impl = struct {

    pub const MIN_YEAR: u16 = 1;
    pub const MAX_YEAR: u16 = 9999;

    // The latemost datetime 9999-12-31 23:59:59
    //
    // If you're curious! 
    // December 31st, 9999
    // 9999 years =  3,649,635 days (9999 × 365)
    // A leap year happens every year divisible by 4: [9999/4] = 2499
    // Century years are not leap years: [9999/100] = 99
    // The 400-year Rule: century years divisible by 400 are leap years: [9999/400] = 24
    // 3,649,635 + 2499 - 99 + 24 = 3652059
    pub const MAX_ORDINAL: u32 = 3652059;

    const DAYS_IN_MONTH = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const DAYS_BEFORE_MONTH = [12]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };

    // Number of days before Jan 1st of year
    fn daysBeforeYear(year: u32) u32 {
        const y: u32 = year - 1;
        return y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
    }

    // Days before 1 Jan 1970
    const EPOCH = daysBeforeYear(1970) + 1;

    fn isLeapYear(year: u32) bool {
        return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    }

    // Number of days in that month for the year
    fn daysInMonth(year: u32, month: u32) u8 {
        assert(1 <= month and month <= 12);
        if (month == 2 and isLeapYear(year)) return 29;
        return DAYS_IN_MONTH[month - 1];
    }

    // Number of days in year preceding the first day of month
    fn daysBeforeMonth(year: u32, month: u32) u32 {
        assert(month >= 1 and month <= 12);
        var d: u32 = DAYS_BEFORE_MONTH[month - 1];
        if (month > 2 and isLeapYear(year)) d += 1;
        return d;
    }

    pub const Time = struct {
        hour: u8 = 0, // 0 to 23
        minute: u8 = 0, // 0 to 59
        second: u8 = 0, // 0 to 59
        nanosecond: u30 = 0, // 0 to 999999999


        pub fn create(hour: u32, minute: u32, second: u32, nanosecond: u32) !Time {
            if (hour > 23 or minute > 59 or second > 59 or nanosecond > 999999999) {
                return error.InvalidTime;
            }
            return Time{
                .hour = @intCast(hour),
                .minute = @intCast(minute),
                .second = @intCast(second),
                .nanosecond = @intCast(nanosecond),
            };
        }

        // Create a copy of the Time
        pub fn fromTimestamp(timestamp: i64) Time {
            const remainder = @mod(timestamp, time.ms_per_day);
            var t: u64 = @abs(remainder);
            // t is now only the time part of the day
            const h: u32 = @intCast(@divFloor(t, time.ms_per_hour));
            t -= h * time.ms_per_hour;
            const m: u32 = @intCast(@divFloor(t, time.ms_per_min));
            t -= m * time.ms_per_min;
            const s: u32 = @intCast(@divFloor(t, time.ms_per_s));
            t -= s * time.ms_per_s;
            const ns: u32 = @intCast(t * time.ns_per_ms);
            return Time.create(h, m, s, ns) catch unreachable;
        }

        // Format as "HH:MM:SS"
        pub fn toIsoString(self: Time, allocator: std.mem.Allocator) ![]u8 {
            return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hour, self.minute, self.second });
        }
    };


    pub const Date = struct {
        year: u16,
        month: u4 = 1, // Month of year
        day: u8 = 1, // Day of month

        // Create and validate the date
        pub fn create(year: u32, month: u32, day: u32) !Date {
            if (year < MIN_YEAR or year > MAX_YEAR) return error.InvalidDate;
            if (month < 1 or month > 12) return error.InvalidDate;
            if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDate;
            // Since we just validated the ranges we can now savely cast
            return Date{
                .year = @intCast(year),
                .month = @intCast(month),
                .day = @intCast(day),
            };
        }

        // Create a Date from the number of days since 01-Jan-0001
        pub fn fromOrdinal(ordinal: u32) Date {
            // n is a 1-based index, starting at 1-Jan-1.  The pattern of leap years
            // repeats exactly every 400 years.  The basic strategy is to find the
            // closest 400-year boundary at or before n, then work with the offset
            // from that boundary to n.  Life is much clearer if we subtract 1 from
            // n first -- then the values of n at 400-year boundaries are exactly
            // those divisible by DI400Y.
            assert(ordinal >= 1 and ordinal <= MAX_ORDINAL);

            var n = ordinal - 1;
            const DI400Y = comptime daysBeforeYear(401); // Num of days in 400 years
            const DI100Y = comptime daysBeforeYear(101); // Num of days in 100 years
            const DI4Y = comptime daysBeforeYear(5); // Num of days in 4   years
            const n400 = @divFloor(n, DI400Y);
            n = @mod(n, DI400Y);
            var year = n400 * 400 + 1; //  ..., -399, 1, 401, ...

            // Now n is the (non-negative) offset, in days, from January 1 of year, to
            // the desired date.  Now compute how many 100-year cycles precede n.
            // Note that it's possible for n100 to equal 4!  In that case 4 full
            // 100-year cycles precede the desired day, which implies the desired
            // day is December 31 at the end of a 400-year cycle.
            const n100 = @divFloor(n, DI100Y);
            n = @mod(n, DI100Y);

            // Now compute how many 4-year cycles precede it.
            const n4 = @divFloor(n, DI4Y);
            n = @mod(n, DI4Y);

            // And now how many single years.  Again n1 can be 4, and again meaning
            // that the desired day is December 31 at the end of the 4-year cycle.
            const n1 = @divFloor(n, 365);
            n = @mod(n, 365);

            year += n100 * 100 + n4 * 4 + n1;

            if (n1 == 4 or n100 == 4) {
                assert(n == 0);
                return Date.create(year - 1, 12, 31) catch unreachable;
            }

            // Now the year is correct, and n is the offset from January 1.  We find
            // the month via an estimate that's either exact or one too large.
            const leapyear = (n1 == 3) and (n4 != 24 or n100 == 3);
            assert(leapyear == isLeapYear(year));
            var month = (n + 50) >> 5;
            if (month == 0) month = 12; // Loop around
            var preceding = daysBeforeMonth(year, month);

            if (preceding > n) { // estimate is too large
                month -= 1;
                if (month == 0) month = 12; // Loop around
                preceding -= daysInMonth(year, month);
            }
            n -= preceding;

            // Now the year and month are correct, and n is the offset from the
            // start of that month:  we're done!
            return Date.create(year, month, n + 1) catch unreachable;
        }

        // Create a date from a UTC timestamp in milliseconds relative to Jan 1st 1970
        pub fn fromTimestamp(timestamp: i64) Date {
            const t = @divFloor(timestamp, time.ms_per_day);
            const d: u64 = @abs(t);
            const days = if (timestamp >= 0) d + EPOCH else EPOCH - d;
            assert(days >= 0 and days <= MAX_ORDINAL);
            return Date.fromOrdinal(@intCast(days));
        }

        // Format as "YYYY-MM-DD"
        pub fn toIsoString(self: Date, allocator: std.mem.Allocator) ![]u8 {
            return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
        }
    };


    pub fn today(vm: *VM) !HostResult {
        const timestamp = std.Io.Clock.real.now(vm.runtime.io).toMilliseconds();
        const date = Date.fromTimestamp(timestamp);
        return .data(try vm.adoptDataString(try date.toIsoString(vm.runtime.alloc)));
    }
};

const testing = revo.lang.testing;
pub const impls = root.impls(Impl).val;

const std = @import("std");
const assert = std.debug.assert;
const time = std.time;


const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const root = @import("root.zig");
const HostResult = root.HostResult;
