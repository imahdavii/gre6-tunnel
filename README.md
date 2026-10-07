# Disk & Log Toolkit

Interactive menu-driven script to diagnose and fix runaway disk usage caused by
bloated syslog files — checks disk space, cleans up stale/oversized log files,
hardens the `rsyslog` logrotate config (`daily`, `maxsize`, `su` directive), and
installs a cron safeguard that runs logrotate every 15 minutes so logs never
silently fill the disk again.

**Developer:** imahdavi

## Quick install & run

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/imahdavii/disk-log-toolkit/main/disk-log-toolkit.sh)
```

## Manual install

```bash
curl -Ls https://raw.githubusercontent.com/imahdavii/disk-log-toolkit/main/disk-log-toolkit.sh -o disk-log-toolkit.sh
chmod +x disk-log-toolkit.sh
sudo ./disk-log-toolkit.sh
```

## Menu options

1. **Check disk & log usage** — shows `df -h /` and the largest files under `/var/log`
2. **Clean oversized / stale logs** — removes old rotated (`syslog.1`, `syslog.2`, ...) and compressed (`*.gz`) log archives; truncates a live `syslog` over 500M
3. **Harden logrotate config** — sets `daily`, `maxsize 200M`, and `su root syslog` on `/etc/logrotate.d/rsyslog`, backing up the original first
4. **Install cron safeguard** — adds `*/15 * * * * /usr/sbin/logrotate /etc/logrotate.d/rsyslog` to root's crontab so oversized logs get rotated well before the daily timer would catch them
5. **Run everything automatically** — runs steps 1-4 in order

## Notes

- Safe to re-run — won't duplicate the cron entry or config directives if already present.
- Backs up `/etc/logrotate.d/rsyslog` before editing (timestamped `.bak` file).
- Tested on Ubuntu (systemd + rsyslog + logrotate).

---

<div dir="rtl">

# ابزار مدیریت دیسک و لاگ

اسکریپت منویی و تعاملی برای تشخیص و رفع پر شدن ناگهانی فضای دیسک به دلیل حجیم شدن
فایل‌های syslog — فضای دیسک رو چک می‌کنه، لاگ‌های قدیمی و حجیم رو پاک‌سازی می‌کنه،
تنظیمات logrotate برای rsyslog رو سخت‌گیرانه‌تر می‌کنه (`daily`، `maxsize`، دایرکتیو
`su`)، و یه کرون‌جاب امنیتی نصب می‌کنه که هر ۱۵ دقیقه logrotate رو اجرا می‌کنه تا
لاگ‌ها دیگه بی‌سروصدا دیسک رو پر نکنن.

**دولوپر:** imahdavi

## نصب و اجرای سریع

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/imahdavii/disk-log-toolkit/main/disk-log-toolkit.sh)
```

## نصب دستی

```bash
curl -Ls https://raw.githubusercontent.com/imahdavii/disk-log-toolkit/main/disk-log-toolkit.sh -o disk-log-toolkit.sh
chmod +x disk-log-toolkit.sh
sudo ./disk-log-toolkit.sh
```

## گزینه‌های منو

۱. **چک فضای دیسک و لاگ‌ها** — نمایش `df -h /` و بزرگ‌ترین فایل‌های داخل `/var/log`

۲. **پاک‌سازی لاگ‌های حجیم و قدیمی** — حذف لاگ‌های چرخش‌خورده‌ی قدیمی (`syslog.1`, `syslog.2`, ...) و آرشیوهای فشرده (`*.gz`)؛ خالی‌کردن (نه حذف) فایل `syslog` فعال در صورتی که بیش از ۵۰۰ مگابایت باشه

۳. **سخت‌گیرانه‌تر کردن تنظیمات logrotate** — تنظیم `daily`، `maxsize 200M`، و `su root syslog` روی `/etc/logrotate.d/rsyslog`، همراه با گرفتن بک‌آپ از فایل اصلی قبل از ویرایش

۴. **نصب کرون‌جاب امنیتی** — اضافه کردن خط `*/15 * * * * /usr/sbin/logrotate /etc/logrotate.d/rsyslog` به crontab کاربر root تا لاگ‌های حجیم خیلی زودتر از تایمر روزانه‌ی logrotate چرخش بخورن

۵. **اجرای خودکار همه‌ی مراحل** — اجرای پیاپی مراحل ۱ تا ۴

## نکات

- اجرای مجدد این اسکریپت کاملاً امنه — خط تکراری به کرون یا کانفیگ اضافه نمی‌کنه اگه از قبل وجود داشته باشه.
- قبل از ویرایش، از `/etc/logrotate.d/rsyslog` بک‌آپ (با مهر زمانی در اسم فایل) گرفته می‌شه.
- روی اوبونتو (با systemd + rsyslog + logrotate) تست شده.

</div>
