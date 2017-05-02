# PHP logger

Logger for any PHP-FPM based project, which seamlessly integrated into standard devops logging solution. 

It was designed in a way, that each PHP application has it's own PHP logger container, but in case you want to share container - you just need to make sure you share necessary volume among all the involved containers. 

#### configuration
It should receive `-q` flag during startup for production usage. Logger accepts following ENV variables:

- TEAM  - configure team this application belongs to. e.g. "elite". This will make filtering and dashboarding easier for teams. 
- APPICATION - configures application name. In case team has more than 1 application - we can see logs for that application specifically. 

#### example input/output:
** php-error input **
```
[27-Apr-2017 15:20:32 America/Los_Angeles] PHP Warning:  Failed to process upsell, errno: 5, session_data: array (
  'payment_session_id' => 1654847,
  'initial_transaction_id' => 15030625,
  'elite_batch_id' => 1814,
  'subscription_id' => 'gntrdw',
  'country' => 'GB',
  'bin_country' => NULL,
  'is_session_replaced' => false,
  'is_popup_mode' => 0,
  'vendor_id' => 19,
  'user_id' => 204087244,
  'upsell_index' => 1,
  'clicks' =>
  array (
    'speed' => 1,
    'device' => 1,
  ),
  'bt_payment_token' => 'mk8f292',
  'physical_cc' => NULL,
) in /srv/app/hsselite/loops/build_2017.04.26.14.07.48_20170426.155757/library/Payment/UpsellManager.php on line 259
[27-Apr-2017 15:37:10 America/Los_Angeles] PHP Warning:  mdecrypt_generic(): An empty string was passed in /srv/app/hsselite/loops/build_2017.04.26.14.07.48_20170426.155757/library/Hss/Crypt/Android.php on line 34

```
** php-error output **
```
{  
   "severity":"Warning",
   "msg":" Failed to process upsell, errno: 5, session_data: array (\n  'payment_session_id' => 1654847,\n  'initial_transaction_id' => 15030625,\n  'elite_batch_id' => 1814,\n  'subscription_id' => 'gntrdw',\n  'country' => 'GB',\n  'bin_country' => NULL,\n  'is_session_replaced' => false,\n  'is_popup_mode' => 0,\n  'vendor_id' => 19,\n  'user_id' => 204087244,\n  'upsell_index' => 1,\n  'clicks' =>\n  array (\n    'speed' => 1,\n    'device' => 1,\n  ),\n  'bt_payment_token' => 'mk8f292',\n  'physical_cc' => NULL,\n) in /srv/app/hsselite/loops/build_2017.04.26.14.07.48_20170426.155757/library/Payment/UpsellManager.php on line 259",
   "hostname":"c651b532168d",
   "event_type":"php.error",
   "team":"default",
   "application":"php",
   "time":"2017-04-27T15:20:32+00:00"
}
{  
   "severity":"Warning",
   "msg":" mdecrypt_generic(): An empty string was passed in /srv/app/hsselite/loops/build_2017.04.26.14.07.48_20170426.155757/library/Hss/Crypt/Android.php on line 34",
   "hostname":"c651b532168d",
   "event_type":"php.error",
   "team":"default",
   "application":"php",
   "time":"2017-04-27T15:37:10+00:00"
}

```

** slow-log input **
```
[28-Apr-2017 10:52:05]  [pool android] pid 381
script_filename = /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/application/desktop/api/a/1/account.php
[0x00007f9f1fc13810] __construct() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/AF/HandlerSocket/Client.php:106
[0x00007f9f1fc13730] getConnection() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/AF/HandlerSocket/Index.php:51
[0x00007f9f1fc13680] getIndex() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/AF/HandlerSocket/IndexRead.php:23
[0x00007f9f1fc13500] find() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/AF/HandlerSocket/IndexRead.php:97
[0x00007f9f1fc13440] select() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/Authorizer.php:211
[0x00007f9f1fc132b0] get() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/Authorizer.php:649
[0x00007f9f1fc13210] getUserPackagesByUserId() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/application/desktop/api/a/1/account.php:48
```
** slow-log output **
```
{  
   "pool":"android",
   "pid":"381",
   "script_name":"/srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/application/desktop/api/a/1/account.php",
   "msg":"[0x00007f9f1fc13810] __construct() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/AF/HandlerSocket/Client.php:106\n[0x00007f9f1fc13730] getConnection() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/AF/HandlerSocket/Index.php:51\n[0x00007f9f1fc13680] getIndex() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/AF/HandlerSocket/IndexRead.php:23\n[0x00007f9f1fc13500] find() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/AF/HandlerSocket/IndexRead.php:97\n[0x00007f9f1fc13440] select() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/Authorizer.php:211\n[0x00007f9f1fc132b0] get() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/library/Authorizer.php:649\n[0x00007f9f1fc13210] getUserPackagesByUserId() /srv/app/hsselite/loops/build_2017.04.27.15.18.24_20170427.160556/application/desktop/api/a/1/account.php:48\n",
   "hostname":"c651b532168d",
   "event_type":"php.slowlog",
   "team":"default",
   "application":"php",
   "time":"2017-04-28T10:52:05+00:00"
}
```
