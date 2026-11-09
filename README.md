# Budgy

A private, Apple-native personal finance app for iPhone, built with SwiftUI, SwiftData, Swift Charts, and Liquid Glass.

## Features
- **Safe to Spend** until your next paycheck, the end of the month, or any date, with a spent-vs-left bar and spending donut
- **Base paycheck budgeting** that treats overtime as extra pay you can send to goals
- **Spending Groups** with automatic grouping, plus a swipe-to-sort tab for anything Budgy isn't sure about
- **Bills & Subscriptions** with automatic detection, price-increase alerts, and renewal reminders
- **Pay Yourself First** tracking for Roth IRA deposits against the yearly limit
- **Goals** with per-paycheck targets and what-if planning
- **Accounts & Investments** with net worth history
- **Advisor** powered by Apple's on-device Foundation Models
- Dark/Light mode, theme colors, alternate app icons, Face ID lock, Siri shortcut

## Project layout
| Folder | Contents |
|---|---|
| `budgy/` | The iOS app (open `budgy.xcodeproj` in Xcode) |
| `Server/` | Cloudflare Worker relay that keeps Plaid keys off the phone; see `Server/README.md` |

## Testing without a bank
In the app, go to **Settings → Bank Connections → Connect Demo Bank** for realistic fake accounts and transactions.

Secrets (Plaid keys, the relay app token) are never stored in this repository.
