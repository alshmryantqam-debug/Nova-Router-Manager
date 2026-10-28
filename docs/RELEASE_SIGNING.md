# توقيع إصدارات نوڨا (Nova)

يشرح هذا الدليل تجهيز مفتاح ثابت لتثبيت تحديثات نوڨا فوق النسخة الحالية دون إزالة التطبيق.

## أسرار GitHub المطلوبة

من المستودع افتح Settings → Secrets and variables → Actions → New repository secret، وأنشئ الأسرار الأربعة التالية بالأسماء الدقيقة:

- ANDROID_KEYSTORE_BASE64: ملف keystore كاملًا بعد تحويله إلى Base64.
- ANDROID_KEYSTORE_PASSWORD: كلمة مرور ملف keystore.
- ANDROID_KEY_ALIAS: الاسم المستعار للمفتاح داخل الملف.
- ANDROID_KEY_PASSWORD: كلمة مرور المفتاح.

يفكّ سير العمل ملف المفتاح مؤقتًا أثناء البناء وينشئ android/key.properties داخل بيئة البناء فقط. لا تضع ملف keystore أو كلمات المرور في Git.

**مهم:** يجب وجود الأسرار الأربعة كلها. إذا غاب أي سر، يستمر البناء بمفتاح Android debug مع تحذير، ويُسمّى APK باسم Nova-DEBUG-KEY.apk. هذا الملف لا يستطيع تحديث تثبيت موقّع بمفتاح إصدار مختلف. جهّز الأسرار قبل توزيع إصدار عام.

## (أ) إنشاء المفتاح على حاسوب

تأكد من وجود Java/JDK ثم نفّذ:

    keytool -genkeypair -v -keystore nova-upload.jks -alias nova -keyalg RSA -keysize 2048 -validity 10000
    base64 -w 0 nova-upload.jks > nova-upload.jks.base64

إذا لم يدعم النظام الخيار -w 0، استخدم:

    base64 nova-upload.jks | tr -d '\n' > nova-upload.jks.base64

احفظ كلمات المرور والاسم المستعار. انسخ محتوى nova-upload.jks.base64 كاملًا إلى ANDROID_KEYSTORE_BASE64، ثم أضف القيم الأخرى إلى الأسرار المقابلة.

## (ب) إنشاء المفتاح من الهاتف عبر Termux

افتح Termux ونفّذ:

    pkg update
    pkg install openjdk-17 coreutils
    mkdir -p ~/nova-signing
    cd ~/nova-signing
    keytool -genkeypair -v -keystore nova-upload.jks -alias nova -keyalg RSA -keysize 2048 -validity 10000
    base64 -w0 nova-upload.jks > nova-upload.jks.base64

أثناء أسئلة keytool، أدخل بياناتك واحفظ كلمات المرور. افتح nova-upload.jks.base64 وانسخ محتواه إلى ANDROID_KEYSTORE_BASE64 في GitHub Secrets، وضع كلمة مرور الملف في ANDROID_KEYSTORE_PASSWORD، والاسم nova في ANDROID_KEY_ALIAS، وكلمة مرور المفتاح في ANDROID_KEY_PASSWORD.

## النسخة الاحتياطية — إلزامية

- احتفظ بنسختين آمنتين من nova-upload.jks خارج GitHub، في مكانين منفصلين؛ واحتفظ بكلمات المرور والاسم المستعار في مدير كلمات مرور.
- لا ترفع keystore أو ملف Base64 إلى GitHub، حتى لو كان المستودع خاصًا.
- اختبر النسخة الاحتياطية وإمكانية قراءة المفتاح قبل حذف أي نسخة.
- **فقدان ملف keystore أو كلمات المرور يعني عدم القدرة على توقيع تحديث متوافق مع النسخ الموزعة بهذا المفتاح.** لن يتمكن المستخدمون من التحديث فوق النسخة القديمة بمفتاح جديد؛ وقد يضطرون إلى إزالة التطبيق وفقد بياناته المحلية.

## الإصدارات والتنزيل

كل بناء ناجح على main يستبدل Release باسم nightly (pre-release) ويرفع ملفات APK مباشرة دون ZIP. عند توفر التوقيع يرفع أيضًا Nova.aab. رقم الإصدار هو 1.0. متبوعًا برقم تشغيل GitHub Actions.
