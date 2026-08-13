import Foundation

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }

    func endOfMonth(for date: Date) -> Date {
        self.date(byAdding: .month, value: 1, to: startOfMonth(for: date))!
    }

    func monthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = self
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }

    func daysInMonthGrid(for date: Date) -> [Date] {
        let monthStart = startOfMonth(for: date)
        let weekday = component(.weekday, from: monthStart)
        var leading = weekday - firstWeekday
        if leading < 0 { leading += 7 }
        let gridStart = startOfDay(for: self.date(byAdding: .day, value: -leading, to: monthStart)!)
        return (0..<42).map { offset in
            startOfDay(for: self.date(byAdding: .day, value: offset, to: gridStart)!)
        }
    }
}
