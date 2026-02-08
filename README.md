# Unofficial calamari.io macOS status bar app

## To use this app you need to provide the app with:
1. Your organization name
2. Your email address
3. Your password

## Features:
1. Start and stop time tracking with a single click on the status bar icon
2. Display the currently tracked time in the status bar menu
3. Select and remember the last used project for time tracking
4. When there is an error in the app, or the internet connection is lost, clicking on the status bar icon will open the app's main window
5. When the internet connection is lost, the app will display a "No internet connection" icon in the status bar.

## How to use:
1. Open the app
2. Sign in
3. Click on the status bar icon to start tracking time
4. Click on the status bar icon again to stop tracking time
5. Observe the tracked time in the app's menu

## Screenshots:
1. After you open the app, you will see the login window:<br>
![calamari-sign-in](https://github.com/kopyl/calamari-status-bar/blob/main/screenshots/calamari-sign-in.png?raw=true)
2. After you sign in, the app will display the current status of time tracking and the total time tracked for the current day. If you currently don't track time (time trackig was NOT launched from web or mobile app), the app will display the non-tracking status like this:<br>
![calamari-status-bar-stopped](https://github.com/kopyl/calamari-status-bar/blob/main/screenshots/calamari-status-bar-stopped.png?raw=true)<br>
The main window looks like this in non-tracking state:<br>
![calamari-main-stopped](https://github.com/kopyl/calamari-status-bar/blob/main/screenshots/calamari-main-stopped.png?raw=true)<br>
3. When you start tracking time, the app will display the currently tracked time for the current day and the tracking status like this:<br>
![calamari-status-bar-running](https://github.com/kopyl/calamari-status-bar/blob/main/screenshots/calamari-status-bar-running.png?raw=true)<br>
The main window looks like this in tracking state:<br>
![calamari-main-running](https://github.com/kopyl/calamari-status-bar/blob/main/screenshots/calamari-main-running.png?raw=true)<br>

## Request collection:

### Login:

##### 1. First app retrieves initial CSRF (non-authenticated) token from the API
```bash
curl -i -s \
    -H "User-Agent: Mozilla/5.0" \
    -H "Accept: application/json, text/plain, */*" \
    -H "Origin: https://auth.calamari.io" \
    -H "Referer: https://auth.calamari.io/" \
    "https://core.calamari.io/webapi/tenant/current-tenant-info"
```
The CSRF token is returned in the response cookies as `_csrf_token`.

##### 2. Then app sends login request with the retrieved CSRF token and user credentials
```bash
curl -i -s 'https://{ORGANIZATION}.calamari.io/sign-in.do' \
  -H 'content-type: application/json' \
  -b '_csrf_token=eedaae8d-a583-45eb-b19a-5f231ee45cff' \
  -H 'x-csrf-token: eedaae8d-a583-45eb-b19a-5f231ee45cff' \
  --data-raw '{"domain":"{ORGANIZATION}","login":"{EMAIL}","password":"{PASSWORD}"}'
```
The response contains a new CSRF token and session cookie (`calamari.cloud.session`) that are used for subsequent authenticated requests.

### Start tracking time:

##### 1. First app sends a request to start the time tracking using initial CSRF token and session cookie
```bash
curl 'https://{ORGANIZATION}.calamari.io/webapi/clock-screen/clock-in' \
  -H 'content-type: application/json' \
  -b $'_csrf_token={CSRF_TOKEN}; calamari.cloud.session={SESSION_COOKIE}' \
  -H 'x-csrf-token: {CSRF_TOKEN}' \
  --data-raw '{}'
```

##### 2. Then immediately after that app sends a request specifying the project ID:
```bash
curl 'https://xxx.calamari.io/webapi/clockin/workloging/from-beginning' \
  -H 'content-type: application/json' \
  -b $'_csrf_token={CSRF_TOKEN}; calamari.cloud.session={SESSION_COOKIE}' \
  -H 'x-csrf-token: {CSRF_TOKEN}' \
  --data-raw '{"projectId":10}'
```

### Stop tracking time:
```bash
curl 'https://xxx.calamari.io/webapi/clock-screen/clock-out' \
  -H 'content-type: application/json' \
  -b $'_csrf_token={CSRF_TOKEN}; calamari.cloud.session={SESSION_COOKIE}' \
  -H 'x-csrf-token: {CSRF_TOKEN}' \
  --data-raw '{}'
```

### Get all projects, current tracking status and total tracked time for the current day:
```bash
curl 'https://xxx.calamari.io/webapi/clock-screen/get' \
  -H 'content-type: application/json' \
  -b $'_csrf_token={CSRF_TOKEN}; calamari.cloud.session={SESSION_COOKIE}' \
  -H 'x-csrf-token: {CSRF_TOKEN}' \
  --data-raw '{}'
```
- The current tracking status is found under `currentState`. It can be either `STARTED` or `STOPPED`.
- The total time tracked for today is calculated by summing up all time entries in `dayShifts`

### FAQ:
1. **The list of projects available for time tracking is disabled, how can I enable it?**
   - To select a different project for time tracking, first you must stop the current time tracking session by clicking on the status bar icon. Then the list of projects will become available for selection.

### Implemnentation details:
- Pressing on the status bar icon when the status is "No internet connection" or "Error" will open the main window
- Pressing on the status bar icon when not logged in will also open the main window