/*
THE COST OF WAITING
Healthcare Referral Scheduling | Reproducible SQLite Analysis
Author: Adrienne Ashley
Data: Fully synthetic, educational dataset; no real patients or implemented pilot.
Database: cost_of_waiting_with_attempts.sqlite
Run in SQLime (SQLite). Each numbered SELECT returns a separate result.

Definitions:
 contact_delay_days: received -> first contact
 scheduling_delay_days: first contact -> booked
 appointment_lead_days: booked -> appointment
 total_wait_days: received -> appointment
 >14 days is an illustrative analysis threshold, NOT a clinical standard.
 The proposed intervention concerns ROUTINE Behavioral Health referrals;
 urgent referrals require independent, clinically approved safeguards.
*/

-- 01. Inventory: confirm source tables and row counts.
SELECT 'referrals' AS dataset, COUNT(*) AS records FROM referrals
UNION ALL
SELECT 'scheduling_attempts', COUNT(*) FROM scheduling_attempts;

-- 02. Category comparison: referral counts, mean scheduling delays,
--     and share exceeding the illustrative 14-day threshold.
SELECT referral_category,
       COUNT(*) AS referrals,
       ROUND(AVG(scheduling_delay_days), 1) AS avg_scheduling_delay_days,
       SUM(CASE WHEN scheduling_delay_days > 14 THEN 1 ELSE 0 END) AS over_14_days,
       ROUND(100.0 * SUM(CASE WHEN scheduling_delay_days > 14 THEN 1 ELSE 0 END)
             / COUNT(*), 1) AS pct_over_14_days
FROM referrals
GROUP BY referral_category
ORDER BY avg_scheduling_delay_days DESC;

-- 03. Behavioral Health waiting-time stages.
SELECT COUNT(*) AS bh_referrals,
       ROUND(AVG(contact_delay_days), 1) AS avg_contact_days,
       ROUND(AVG(scheduling_delay_days), 1) AS avg_scheduling_days,
       ROUND(AVG(appointment_lead_days), 1) AS avg_appointment_lead_days,
       ROUND(AVG(total_wait_days), 1) AS avg_total_wait_days,
       ROUND(100.0 * SUM(scheduling_delay_days) / NULLIF(SUM(total_wait_days),0),1)
           AS pct_wait_at_scheduling_stage
FROM referrals
WHERE referral_category = 'Behavioral Health';

-- 04. Urgent and routine Behavioral Health referrals must be distinguished.
SELECT priority, COUNT(*) AS referrals,
       ROUND(AVG(scheduling_delay_days), 1) AS avg_scheduling_days,
       MIN(scheduling_delay_days) AS shortest_delay_days,
       MAX(scheduling_delay_days) AS longest_delay_days,
       SUM(CASE WHEN scheduling_delay_days > 14 THEN 1 ELSE 0 END) AS over_14_days,
       ROUND(100.0 * SUM(CASE WHEN scheduling_delay_days > 14 THEN 1 ELSE 0 END)
             / COUNT(*),1) AS pct_over_14_days
FROM referrals
WHERE referral_category = 'Behavioral Health'
GROUP BY priority;

-- 05. Monthly routine Behavioral Health volume and scheduling delays.
SELECT SUBSTR(received_date,1,7) AS referral_month,
       COUNT(*) AS referral_volume,
       ROUND(AVG(scheduling_delay_days),1) AS avg_scheduling_delay_days
FROM referrals
WHERE referral_category='Behavioral Health' AND priority='Routine'
GROUP BY SUBSTR(received_date,1,7)
ORDER BY referral_month;

-- 06. Pearson correlation between MONTHLY volume and MONTHLY mean delay.
--     Descriptive association only; small monthly sample, no causal inference.
WITH monthly AS (
  SELECT SUBSTR(received_date,1,7) AS month,
         COUNT(*) AS volume, AVG(scheduling_delay_days) AS delay
  FROM referrals
  WHERE referral_category='Behavioral Health' AND priority='Routine'
  GROUP BY SUBSTR(received_date,1,7)
)
SELECT COUNT(*) AS months,
       ROUND((AVG(volume*delay)-AVG(volume)*AVG(delay)) /
       NULLIF(SQRT((AVG(volume*volume)-AVG(volume)*AVG(volume)) *
                   (AVG(delay*delay)-AVG(delay)*AVG(delay))),0),3)
       AS pearson_r
FROM monthly;

-- 07. Unsuccessful attempt barriers, by category.
SELECT r.referral_category, sa.barrier_reason,
       COUNT(*) AS unsuccessful_attempts,
       COUNT(DISTINCT sa.referral_id) AS affected_referrals
FROM scheduling_attempts sa
JOIN referrals r ON r.referral_id=sa.referral_id
WHERE sa.outcome='Unsuccessful'
GROUP BY r.referral_category,sa.barrier_reason
ORDER BY r.referral_category, unsuccessful_attempts DESC;

-- 08. Behavioral Health scheduling barrier exposure vs delay.
--     A referral can have multiple barriers; count DISTINCT referrals.
WITH slot_barrier AS (
 SELECT DISTINCT referral_id FROM scheduling_attempts
 WHERE outcome='Unsuccessful' AND barrier_reason='No appointment slots'
)
SELECT CASE WHEN s.referral_id IS NOT NULL THEN 'Slot barrier recorded'
            ELSE 'No slot barrier recorded' END AS group_name,
       COUNT(*) AS referrals,
       ROUND(AVG(r.scheduling_delay_days),1) AS avg_scheduling_delay_days
FROM referrals r
LEFT JOIN slot_barrier s ON s.referral_id=r.referral_id
WHERE r.referral_category='Behavioral Health'
GROUP BY CASE WHEN s.referral_id IS NOT NULL THEN 1 ELSE 0 END;

-- 09. Number of unsuccessful attempts per Behavioral Health referral.
WITH unsuccessful AS (
 SELECT referral_id, COUNT(*) AS attempts
 FROM scheduling_attempts WHERE outcome='Unsuccessful'
 GROUP BY referral_id
)
SELECT COALESCE(u.attempts,0) AS unsuccessful_attempts,
       COUNT(*) AS referrals,
       ROUND(AVG(r.scheduling_delay_days),1) AS avg_scheduling_delay_days
FROM referrals r LEFT JOIN unsuccessful u ON r.referral_id=u.referral_id
WHERE r.referral_category='Behavioral Health'
GROUP BY COALESCE(u.attempts,0)
ORDER BY unsuccessful_attempts;

-- 10. Routine Behavioral Health hybrid review rule:
--     three unsuccessful attempts OR >10 days from first contact to booking.
--     Retrospective classification, NOT a prospective alert simulation.
WITH counts AS (
 SELECT referral_id,COUNT(*) AS unsuccessful_attempts
 FROM scheduling_attempts WHERE outcome='Unsuccessful'
 GROUP BY referral_id
), classified AS (
 SELECT r.referral_id,r.scheduling_delay_days,
        COALESCE(c.unsuccessful_attempts,0) AS attempts,
        CASE WHEN COALESCE(c.unsuccessful_attempts,0)>=3
                   OR r.scheduling_delay_days>10
             THEN 'Flag for review' ELSE 'Standard monitoring' END AS review_group
 FROM referrals r LEFT JOIN counts c ON r.referral_id=c.referral_id
 WHERE r.referral_category='Behavioral Health' AND r.priority='Routine'
)
SELECT review_group, COUNT(*) AS referrals,
       ROUND(AVG(scheduling_delay_days),1) AS avg_scheduling_delay_days,
       SUM(CASE WHEN scheduling_delay_days>14 THEN 1 ELSE 0 END) AS over_14_days
FROM classified GROUP BY review_group;

-- 11. Identify which condition triggered retrospective classification.
WITH counts AS (
 SELECT referral_id,COUNT(*) AS unsuccessful_attempts
 FROM scheduling_attempts WHERE outcome='Unsuccessful'
 GROUP BY referral_id
), classified AS (
 SELECT r.referral_id,
        COALESCE(c.unsuccessful_attempts,0)>=3 AS attempts_trigger,
        r.scheduling_delay_days>10 AS time_trigger
 FROM referrals r LEFT JOIN counts c ON c.referral_id=r.referral_id
 WHERE r.referral_category='Behavioral Health' AND r.priority='Routine'
)
SELECT CASE WHEN attempts_trigger AND time_trigger THEN 'Both conditions'
            WHEN attempts_trigger THEN 'Attempts only'
            WHEN time_trigger THEN 'Time only'
            ELSE 'Neither' END AS trigger_reason,
       COUNT(*) AS referrals
FROM classified GROUP BY trigger_reason ORDER BY referrals DESC;

-- 12. Verify third unsuccessful attempt chronology and early-alert eligibility.
--     Attempt must be on/after first contact and BEFORE booking.
WITH numbered AS (
 SELECT r.referral_id,r.first_contact_date,r.scheduled_date,sa.attempt_date,
        ROW_NUMBER() OVER (PARTITION BY r.referral_id
                           ORDER BY sa.attempt_date,sa.attempt_id) AS attempt_number
 FROM referrals r JOIN scheduling_attempts sa ON sa.referral_id=r.referral_id
 WHERE r.referral_category='Behavioral Health' AND r.priority='Routine'
   AND sa.outcome='Unsuccessful'
), third_attempts AS (
 SELECT * FROM numbered WHERE attempt_number=3
)
SELECT COUNT(*) AS third_attempt_referrals,
       SUM(CASE WHEN attempt_date<first_contact_date THEN 1 ELSE 0 END)
           AS before_first_contact,
       SUM(CASE WHEN attempt_date>=scheduled_date THEN 1 ELSE 0 END)
           AS on_or_after_booking,
       SUM(CASE WHEN attempt_date>=first_contact_date
                 AND attempt_date<scheduled_date
                 AND JULIANDAY(attempt_date)-JULIANDAY(first_contact_date)<10
                THEN 1 ELSE 0 END) AS valid_early_flags
FROM third_attempts;

-- 13. Valid early alerts: how many days before the day-10 backstop?
WITH numbered AS (
 SELECT r.referral_id,r.first_contact_date,r.scheduled_date,sa.attempt_date,
        ROW_NUMBER() OVER (PARTITION BY r.referral_id
                           ORDER BY sa.attempt_date,sa.attempt_id) AS attempt_number
 FROM referrals r JOIN scheduling_attempts sa ON sa.referral_id=r.referral_id
 WHERE r.referral_category='Behavioral Health' AND r.priority='Routine'
   AND sa.outcome='Unsuccessful'
), eligible AS (
 SELECT referral_id, JULIANDAY(attempt_date)-JULIANDAY(first_contact_date)
        AS days_to_third_attempt
 FROM numbered
 WHERE attempt_number=3 AND attempt_date>=first_contact_date
   AND attempt_date<scheduled_date
   AND JULIANDAY(attempt_date)-JULIANDAY(first_contact_date)<10
)
SELECT COUNT(*) AS early_alerts,
       ROUND(AVG(10-days_to_third_attempt),1) AS avg_days_earlier,
       MAX(10-days_to_third_attempt) AS maximum_days_earlier
FROM eligible;

-- 14. Individual valid early-warning referrals (synthetic IDs).
WITH numbered AS (
 SELECT r.referral_id,r.scheduling_delay_days,r.first_contact_date,
        r.scheduled_date,sa.attempt_date,
        ROW_NUMBER() OVER (PARTITION BY r.referral_id
                           ORDER BY sa.attempt_date,sa.attempt_id) AS attempt_number
 FROM referrals r JOIN scheduling_attempts sa ON sa.referral_id=r.referral_id
 WHERE r.referral_category='Behavioral Health' AND r.priority='Routine'
   AND sa.outcome='Unsuccessful'
)
SELECT referral_id,scheduling_delay_days,
       CAST(JULIANDAY(attempt_date)-JULIANDAY(first_contact_date) AS INTEGER)
           AS days_until_third_attempt
FROM numbered
WHERE attempt_number=3 AND attempt_date>=first_contact_date
  AND attempt_date<scheduled_date
  AND JULIANDAY(attempt_date)-JULIANDAY(first_contact_date)<10
ORDER BY days_until_third_attempt,referral_id;

/*
PROPOSED PILOT DESIGN (NOT RUN ON THIS DATASET)

- Scope: routine Behavioral Health referrals, Clinic A (intervention) vs
  comparable Clinic B (usual process).
- Primary target: >=3 additional days of improvement relative to Clinic B,
  in EACH of three consecutive pilot months.
- Establish a comparable pre-intervention baseline for each clinic.
- Check pre-intervention trends, case mix, staffing, capacity, referral volume,
  and concurrent process changes. Difference-in-differences is an estimate
  under assumptions, not automatic proof of causality.
- Balance: total administrative minutes per referral, alerts per referral,
  staff-rated burden, overtime, unresolved queues, and urgent-referral safety.
- Establish workload guardrails after representative baseline collection.
- Track open/unscheduled referrals and censoring: a completed-only average
  can misleadingly improve if delayed referrals remain unscheduled.
- Define calendar cohorts, minimum sample sizes, and data completeness before
  rollout. Three months alone may not support reliable causal attribution.

FUTURE DATA REQUIREMENTS (NOT PRESENT IN THIS DATABASE):
 clinic_id, intervention_active, actual cohort dates, staffing/capacity,
 staff_activity records (one row per activity), referral open/closed status,
 and repeated pre/post observations for BOTH clinics.

Illustrative difference-in-differences calculation, per pilot month:
 effect_days = (A_baseline_avg - A_pilot_month_avg)
             - (B_baseline_avg - B_pilot_month_avg)
 Target met when effect_days >= 3 for EACH of 3 consecutive months,
 subject to safety and workload guardrails.
*/
