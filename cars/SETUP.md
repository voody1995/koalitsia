# שמות לרכבים — הקמה

כתובת: https://voody1995.github.io/koalitsia/cars/

## 1. מסד הנתונים (Supabase, אותו פרויקט של המשחק)
1. SQL Editor → להדביק את כל `cars/schema.sql` → Run.
2. Project Settings → Data API → Exposed schemas → להוסיף `car_names` → Save.

## 2. התחברות עם Google
**ב־Google Cloud Console** (console.cloud.google.com):
1. ליצור פרויקט (או להשתמש בקיים).
2. APIs & Services → OAuth consent screen: סוג External, שם האפליקציה, המייל שלך. בלשונית Audience ללחוץ **Publish app** (אחרת רק משתמשי בדיקה יוכלו להיכנס). אין צורך באימות של גוגל, כי מבקשים רק שם ומייל.
3. APIs & Services → Credentials → Create credentials → OAuth client ID → Web application.
   - Authorized redirect URIs: `https://waedapydxuatsspkvxwr.supabase.co/auth/v1/callback`
4. להעתיק את ה־Client ID וה־Client secret.

**ב־Supabase:**
1. Authentication → Sign In / Providers → Google → Enable, להדביק Client ID ו־Client secret → Save.
2. Authentication → URL Configuration → Redirect URLs → להוסיף `https://voody1995.github.io/koalitsia/cars/`

## שינויים נפוצים
- להזיז את מועד הסגירה: `update car_names.settings set deadline = '2026-11-07 23:59:00+02';`
- להוסיף מנהל: `insert into car_names.admins values ('someone@gmail.com');`
- מסך ניהול: כפתור "ניהול" למעלה (מופיע רק למנהלים), או `#admin` בסוף הכתובת.
