---
name: budgy-finance
description: Personal-finance domain rules for Budgy — how to save (pay yourself first, emergency fund sizing), invest (the "next dollar" priority ladder, Roth IRA pacing), raise a credit score (utilization math, statement vs. due date, payment history, what never to suggest), and manage subscriptions (recurring-charge detection, price increases, stale and charged-after-cancel subscriptions). Use whenever changing FinanceEngine, MoneyHealth, RecurringDetector, NotificationService, the Advisor's tools or instructions, or any screen that shows money advice, credit utilization, savings progress, or subscriptions. Pair with budgy-design for UI and write-swift for Swift.
---

# Budgy Finance

Budgy exists to do four things for one person: **save money, invest money, raise their credit
score, and manage subscriptions.** Every feature should move one of those four. This skill holds the
domain rules so code and copy stay correct. It is distilled from the open-source
`credit-score-improvement` skill (FerroxLabs/murage, Apache-2.0), `subscription-detection`
(peerjakobsen/smartspender), Plaid's `/transactions/recurring` stream model, and standard
personal-finance practice. Budgy is not a licensed advisor; it shows the user's own numbers and
the well-established rules, and never guarantees outcomes.

## Where things live

| Rule area | Code |
|---|---|
| Safe to Spend, budget month, pay-yourself-first reserve | `budgy/Engine/FinanceEngine.swift`, `BudgetMonth.swift` |
| Credit, emergency fund, next-dollar ladder, subscription insights | `budgy/Engine/MoneyHealth.swift` |
| Recurring detection and price changes | `budgy/Engine/RecurringDetector.swift` |
| Per-card utilization, statement/due dates | `Account` in `budgy/Models/Models.swift` |
| Reminders (statement close, due date, renewals, payday) | `budgy/Services/NotificationService.swift` |
| On-device Advisor (Foundation Models tools + instructions) | `budgy/Advisor/AdvisorTools.swift`, `AdvisorView.swift` |

Keep calculations in the engine (pure, testable structs over model arrays). Views only format.
The Advisor gets numbers through `FinanceContext`, never by computing them in a prompt.

---

## 1. Saving

**Pay yourself first.** Savings come out of each *base* paycheck before anything is spendable
(`PaySchedule.savingsRate`, default 33%). Overtime and bonuses are "extra pay" the user assigns
on purpose; never budget on them.

**Emergency fund.** It's measured in *months of spending covered*, not dollars.
- Monthly spending = trailing 90-day average of real spending (`spendingAmount`, which includes
  bills and subscriptions). If there's under ~60 days of history, fall back to monthly bills +
  subscriptions + category budgets.
- Emergency money = savings-account balance not earmarked by other goals. A goal whose name
  contains "emergency" counts as emergency money itself.
- Milestones: **starter cushion** = the smaller of $1,000 or one month; **solid** = 3 months;
  **full** = 6 months. Users with variable income (overtime, commission) should aim toward 6.
- Savings is never Safe to Spend (`AccountKind.isSpendableCash` is checking only). Keep it that way.

## 2. Investing: the next-dollar ladder

When someone asks "where should my next dollar go?", walk this order and stop at the first
unmet step. `FinanceEngine.nextMoneyStep` implements it.

1. **Starter cushion** ($1,000 or one month, whichever is smaller), so a surprise bill
   doesn't land on a credit card.
2. **Stop paying card interest.** If any interest charges were posted recently
   (Plaid detailed category `BANK_FEES_INTEREST_CHARGE`), or card balances exceed checking
   cash, paying cards in full comes before investing. Card APRs (20%+) beat any expected return.
3. **Employer 401(k) match.** Budgy can't see match terms, so mention it as a note on the
   later steps and never assert the user has one.
4. **Emergency fund to 3 months.**
5. **Roth IRA** up to the annual limit (`rothAnnualLimit` in settings; the user keeps it current).
   Show the per-paycheck amount needed to finish by Dec 31.
6. **Invest more**: raise the savings rate, increase 401(k) contributions, or use a brokerage.
   Recommend broad, low-cost index funds as a category; **never recommend specific securities**.

Never move money. Every step is a suggestion with an "I moved it" confirmation.

## 3. Credit score

FICO 8 weights, for prioritizing: payment history 35%, amounts owed / utilization 30%,
length of history 15%, credit mix 10%, new credit 10%. Budgy can influence the first two
directly, so it focuses on them.

**Utilization rules (most commonly gotten wrong):**
- **Per-card and overall both count.** One card at 90% hurts even if overall is 8%. Show both;
  pay down the *highest-utilization card first*.
- **Statement closing date, not due date**, is when the balance is usually reported. To lower
  reported utilization, pay *before the statement closes* (`Account.statementClosingDay`).
  The due date (`paymentDueDay`) is about avoiding interest and late marks.
- Bands (non-linear): under 10% excellent · 10–29% good · 30–49% fair · 50–69% high ·
  70%+ very high. Budgy's must-do target is 29% per card (a margin under 30%); the stretch
  target is under 10% overall.
- Paying in full every month avoids interest. Reported utilization is a separate question,
  so a card paid in full can still report high if the statement closed with a big balance.

**Payment history:**
- A payment 30+ days late is the single most damaging event and the harm doesn't scale with
  how late. Due-date reminders must never be removed. A late fee (`BANK_FEES_LATE_PAYMENT`)
  is a warning that a reported late is close.
- Autopay for at least the minimum is the baseline recommendation.

**Never suggest:**
- Closing old cards. It raises utilization and eventually shortens history.
- Opening new cards or loans just to "build credit mix". It costs a hard inquiry (~5–10 points
  for ~12 months) and lowers average age.
- Specific point gains ("this will raise your score 40 points"). Use *high / medium / low
  impact* language only.
- Disputing accurate items, or anything about paying old collections (re-aging risk). Refer out.

## 4. Subscriptions

**Detection** (`RecurringDetector.detect`): same normalized merchant (`String.merchantKey`),
a steady interval matching a `Frequency`, steady amounts, 3+ occurrences (yearly may have 2),
and recent (last charge within ~1.6 intervals). Everything detected lands in **Found for You**
for confirmation (`needsReview`). Never silently add.

**Price increases:** a step up in amount is a price increase to flag, not a reason to drop the
subscription from detection. Show the yearly difference
(`(new − old) × occurrencesPerYear`). Bills (utilities) vary naturally and get no price alerts.

**Lifecycle insights** (`FinanceEngine.subscriptionInsights`):
- **Renewing soon**: yearly and quarterly subscriptions due within 30 days. Annual
  renewals are the expensive surprises, so remind at least 7 days ahead.
- **No recent charge**: an active subscription whose last charge is older than ~1.6 intervals
  + 7 days. It may have been cancelled, so offer "Mark as ended".
- **Charged after cancelling**: an item the user switched off (`cancelledAt` set) with a
  matching charge afterwards. This is the highest-value alert; show it first, in red.
- Always show subscriptions in monthly *and* yearly terms. The yearly number is the one that
  motivates cancelling.

Plaid's `/transactions/recurring` returns `MATURE` / `EARLY_DETECTION` / `TOMBSTONED`
streams. If Budgy ever adopts it, map `MATURE` to active, `EARLY_DETECTION` to Found for You,
and `TOMBSTONED` to ended. Don't show tombstoned streams as active.

---

## Copy and advice guardrails

- State the user's own numbers: "Pay $212 before Mar 3 to report under 30%" beats "lower your
  utilization".
- No guarantees, no point estimates for credit scores, no specific securities, no tax advice
  beyond "check with a professional when it matters".
- One next step at a time. The ladder exists so Home shows *one* thing to do, not six.
- Follow `budgy-design` §7 for tone (plain, calm, no exclamation marks in body copy).

## Before you call it done

- [ ] Math lives in the engine; views format only.
- [ ] Per-card *and* overall utilization handled; statement date used for reporting advice.
- [ ] Nothing suggests closing cards, opening credit for mix, or promises score points.
- [ ] Savings never counted as spendable; extra pay never budgeted.
- [ ] New Advisor facts are added to `FinanceContext` and exposed through a tool.
- [ ] New `@Model` properties have defaults (CloudKit-compatible, lightweight migration).
