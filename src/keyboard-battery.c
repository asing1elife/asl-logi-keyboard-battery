// Read-only HID++ battery bridge for one Logitech PRO X TKL.
// Battery publication uses macOS IOKit SPI, not a supported public API.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    IOHIDDeviceRef device;
    uint8_t input[64], reply[64];
    int length, index, feature, function;
} Channel;
typedef struct { int percent, status; bool charging, full; char transport[16]; } Battery;
typedef IOReturn (*CreateSource)(void **);
typedef IOReturn (*UpdateSource)(void *, CFDictionaryRef);
typedef IOReturn (*ReleaseSource)(void *);
static volatile sig_atomic_t stopping;
enum Activity { ACTIVE, IDLE, ACTIVITY_UNKNOWN };
enum { IDLE_SECONDS=30 };
typedef struct { int previous; double due; } PollSchedule;
static bool query_interrupted;

// IOHIDSystem's cached counter describes aggregate user input. Reading it does
// not open a peripheral, send HID reports, capture keys, or prevent sleep.
static double system_idle_seconds(void) {
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOHIDSystem"));
    if(!service)return -1;
    CFTypeRef value=IORegistryEntryCreateCFProperty(service,CFSTR("HIDIdleTime"),NULL,0);
    IOObjectRelease(service);
    int64_t ns=-1;
    if(value) {
        if(CFGetTypeID(value)==CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)value,kCFNumberSInt64Type,&ns);
        CFRelease(value);
    }
    return ns<0?-1:(double)ns/1e9;
}
static double (*idle_reader)(void)=system_idle_seconds;
static enum Activity activity_state(void) {
    double idle=idle_reader();
    if(idle<0)return ACTIVITY_UNKNOWN;
    return idle>=IDLE_SECONDS?IDLE:ACTIVE;
}
static bool device_access_allowed(void) {
    if(stopping)return false;
    if(activity_state()!=ACTIVE){query_interrupted=true;return false;}
    return true;
}
static bool poll_due(PollSchedule *s,enum Activity activity,double now) {
    if(activity!=ACTIVE){s->previous=activity;return false;}
    if(s->previous!=ACTIVE)s->due=now;
    s->previous=activity;
    return now>=s->due;
}
static void poll_finished(PollSchedule *s,double now,bool available) {
    s->due=now+(available?60:15);
}
static void stop(int sig) { (void)sig; stopping=1; }
static void log_message(const char *message) {
    char date[32]; time_t now=time(NULL);
    strftime(date,sizeof(date),"%Y-%m-%d %H:%M:%S",localtime(&now));
    fprintf(stderr,"%s %s\n",date,message); fflush(stderr);
}
static void input_report(void *ctx, IOReturn result, void *sender,
                         IOHIDReportType type, uint32_t reportID,
                         uint8_t *report, CFIndex length) {
    (void)sender; (void)type; (void)reportID;
    Channel *c=ctx;
    if(result || length<4 || (report[0]!=0x10 && report[0]!=0x11) || report[1]!=c->index) return;
    bool answer=report[2]==c->feature && report[3]==c->function;
    bool error=length>=6 && report[2]==0xff && report[3]==c->feature && report[4]==c->function;
    if(answer || error) {
        c->length=(int)(length>64?64:length);
        memcpy(c->reply,report,c->length);
    }
}
static bool request(Channel *c,int feature,int function,int a,int b) {
    // Recheck immediately before every transmission: a scan can cross the
    // idle threshold while waiting for another receiver slot to respond.
    if(!device_access_allowed()) return false;
    uint8_t data[20]={0x11,c->index,feature,function,a,b};
    c->length=0; c->feature=feature; c->function=function;
    if(IOHIDDeviceSetReport(c->device,kIOHIDReportTypeOutput,0x11,data,sizeof(data))) return false;
    double end=CFAbsoluteTimeGetCurrent()+0.4;
    while(!stopping && !c->length && CFAbsoluteTimeGetCurrent()<end)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
    return c->length>=7 && c->reply[2]==feature && c->reply[3]==function;
}
static int feature_index(Channel *c,int feature) {
    return request(c,0,0x0a,feature>>8,feature&255)?c->reply[4]:0;
}
static bool is_target(Channel *c) {
    int feature=feature_index(c,0x0005);
    if(!feature || !request(c,feature,0x0a,0,0)) return false;
    int length=c->reply[4];
    if(length<1 || length>63) return false;
    char name[64]={0};
    for(int offset=0;offset<length;) {
        if(!request(c,feature,0x1a,offset,0)) return false;
        int n=c->length-4; if(n>length-offset)n=length-offset;
        if(n<=0)return false;
        memcpy(name+offset,c->reply+4,n);offset+=n;
    }
    return strcmp(name,"PRO X TKL")==0;
}
static bool read_channel(Channel *c,Battery *battery) {
    int feature=feature_index(c,0x1004);
    if(!feature || !request(c,feature,0x1a,0,0) || c->length<8) return false;
    int percent=c->reply[4],level=c->reply[5],status=c->reply[6];
    if(percent>100 || status>4 || (percent==0 && level>1))return false;
    battery->percent=percent; battery->status=status;
    battery->charging=status==1 || status==2 || status==4;
    battery->full=status==3;
    return true;
}
static int number_property(IOHIDDeviceRef d,CFStringRef key) {
    CFTypeRef value=IOHIDDeviceGetProperty(d,key); int number=-1;
    if(value && CFGetTypeID(value)==CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value,kCFNumberIntType,&number);
    return number;
}
static bool scan(Battery *battery) {
    if(!device_access_allowed())return false;
    IOHIDManagerRef m=IOHIDManagerCreate(NULL,0);
    CFMutableDictionaryRef match=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    int vendor=0x046d,page=0xff00;
    CFNumberRef v=CFNumberCreate(NULL,kCFNumberIntType,&vendor),p=CFNumberCreate(NULL,kCFNumberIntType,&page);
    CFDictionarySetValue(match,CFSTR(kIOHIDVendorIDKey),v);
    CFDictionarySetValue(match,CFSTR(kIOHIDPrimaryUsagePageKey),p);
    IOHIDManagerSetDeviceMatching(m,match);
    CFSetRef devices=IOHIDManagerCopyDevices(m);
    CFIndex count=devices?CFSetGetCount(devices):0;
    const void **items=count?calloc((size_t)count,sizeof(void *)):NULL;
    if(count && !items) { if(devices)CFRelease(devices);CFRelease(match);CFRelease(v);CFRelease(p);CFRelease(m);return false; }
    if(count)CFSetGetValues(devices,items);
    bool found=false;
    // Prefer the direct wired/Bluetooth keyboard, then known attached receivers.
    // No audio-device interfaces or keyboard key-report interfaces are opened.
    for(int pass=0;pass<2 && !found && !stopping;pass++) {
        for(CFIndex i=0;i<count && !found && !stopping;i++) {
            IOHIDDeviceRef device=(IOHIDDeviceRef)items[i];
            int pid=number_property(device,CFSTR(kIOHIDProductIDKey));
            bool direct=pid==0xc352 || pid==0xb382;
            bool receiver=pid==0xc53a || pid==0xc547;
            if((pass==0 && !direct) || (pass==1 && !receiver))continue;
            if(!device_access_allowed())break;
            if(IOHIDDeviceOpen(device,kIOHIDOptionsTypeNone))continue;
            Channel c={.device=device};
            IOHIDDeviceRegisterInputReportCallback(device,c.input,sizeof(c.input),input_report,&c);
            IOHIDDeviceScheduleWithRunLoop(device,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
            for(int index=direct?255:1;index<=(direct?255:6) && !found && !stopping;index++) {
                if(!device_access_allowed())break;
                c.index=index;
                if((direct || is_target(&c)) && read_channel(&c,battery)) {
                    CFTypeRef transport=IOHIDDeviceGetProperty(device,CFSTR(kIOHIDTransportKey));
                    strcpy(battery->transport,"USB");
                    if(transport && CFGetTypeID(transport)==CFStringGetTypeID() &&
                       CFStringFind((CFStringRef)transport,CFSTR("Bluetooth"),0).location!=kCFNotFound)
                        strcpy(battery->transport,"Bluetooth");
                    found=true;
                }
            }
            IOHIDDeviceUnscheduleFromRunLoop(device,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
            IOHIDDeviceRegisterInputReportCallback(device,c.input,sizeof(c.input),NULL,NULL);
            IOHIDDeviceClose(device,0);
        }
    }
    free(items); if(devices)CFRelease(devices);
    CFRelease(match);CFRelease(v);CFRelease(p);CFRelease(m);
    return found;
}
static CFDictionaryRef details(const Battery *b) {
    CFMutableDictionaryRef d=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    #define S(k,v) CFDictionarySetValue(d,CFSTR(k),CFSTR(v))
    #define B(k,v) CFDictionarySetValue(d,CFSTR(k),(v)?kCFBooleanTrue:kCFBooleanFalse)
    S("Name","PRO X TKL");S("Type","Accessory Source");S("Accessory Category","Keyboard");
    S("Accessory Identifier","local.keyboard-battery.logitech.pro-x-tkl");
    CFDictionarySetValue(d,CFSTR("Transport Type"),strcmp(b->transport,"Bluetooth")==0?CFSTR("Bluetooth"):CFSTR("USB"));
    CFDictionarySetValue(d,CFSTR("Power Source State"),b->charging||b->full?CFSTR("AC Power"):CFSTR("Battery Power"));
    B("Is Present",true);B("Is Charging",b->charging);B("Is Charged",b->full);
    int max=100,low=20;
    CFNumberRef n=CFNumberCreate(NULL,kCFNumberIntType,&b->percent),mx=CFNumberCreate(NULL,kCFNumberIntType,&max),lw=CFNumberCreate(NULL,kCFNumberIntType,&low);
    CFDictionarySetValue(d,CFSTR("Current Capacity"),n);CFDictionarySetValue(d,CFSTR("Max Capacity"),mx);CFDictionarySetValue(d,CFSTR("Low Warn Level"),lw);
    CFRelease(n);CFRelease(mx);CFRelease(lw);
    return d;
}
int main(int argc,char **argv) {
    signal(SIGINT,stop);signal(SIGTERM,stop);
    if(argc==2 && strcmp(argv[1],"--activity")==0) {
        double idle=idle_reader();
        printf("{\"idle_seconds\":%.3f,\"pause_after_seconds\":%d,\"queries_allowed\":%s}\n",
               idle,IDLE_SECONDS,idle>=0 && idle<IDLE_SECONDS?"true":"false");
        return idle<0?2:0;
    }
    if(argc==2 && strcmp(argv[1],"--once")==0) {
        Battery b={0};
        if(!scan(&b)){
            puts(query_interrupted?"{\"available\":false,\"paused\":true,\"reason\":\"idle_or_activity_unknown\"}":"{\"available\":false}");
            return 2;
        }
        printf("{\"available\":true,\"name\":\"PRO X TKL\",\"percent\":%d,\"charging\":%s,\"full\":%s,\"transport\":\"%s\"}\n",b.percent,b.charging?"true":"false",b.full?"true":"false",b.transport);return 0;
    }
    if(argc!=3 || strcmp(argv[1],"--run")!=0) {
        fprintf(stderr,"Usage: %s --activity | --once | --run /absolute/path/to/lockfile\n",argv[0]);return 2;
    }
    int lock=open(argv[2],O_CREAT|O_RDWR,0600);
    if(lock<0 || flock(lock,LOCK_EX|LOCK_NB)) {log_message("Cannot acquire lock; another bridge may already be running.");return 3;}
    void *lib=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY);
    CreateSource create=lib?(CreateSource)dlsym(lib,"IOPSCreatePowerSource"):NULL;
    UpdateSource update=lib?(UpdateSource)dlsym(lib,"IOPSSetPowerSourceDetails"):NULL;
    ReleaseSource release=lib?(ReleaseSource)dlsym(lib,"IOPSReleasePowerSource"):NULL;
    if(!create||!update||!release){log_message("Required IOKit private interfaces unavailable.");close(lock);return 4;}
    void *source=NULL;int last=-1,lastStatus=-1;bool unavailableLogged=false;
    PollSchedule schedule={.previous=-1,.due=0};int lastActivity=-1;
    log_message("Started. Pausing queries after 30 seconds without user input; checking activity once per second.");
    while(!stopping) {
        enum Activity activity=activity_state();
        if((int)activity!=lastActivity) {
            if(activity==IDLE)log_message("Idle: keyboard queries paused; retaining last known battery reading.");
            else if(activity==ACTIVITY_UNKNOWN)log_message("Activity unavailable: keyboard queries paused for safety; retaining last known reading.");
            else log_message("User active: refreshing battery now.");
            lastActivity=activity;
        }
        if(!poll_due(&schedule,activity,CFAbsoluteTimeGetCurrent())){sleep(1);continue;}
        query_interrupted=false;
        Battery b={0};bool available=scan(&b);
        if(stopping)break;
        // An idle transition is not a disconnected keyboard. Keep the cached
        // item and force an immediate refresh when activity can be confirmed.
        if(query_interrupted){schedule.previous=ACTIVITY_UNKNOWN;sleep(1);continue;}
        if(available) {
            IOReturn r=source?0:create(&source);
            CFDictionaryRef d=details(&b);
            if(!r)r=update(source,d);
            CFRelease(d);
            if(r) {
                char message[128];snprintf(message,sizeof(message),"Publication failed: 0x%x",r);log_message(message);
                if(source){release(source);source=NULL;}last=-1;
            } else {
                if(last!=b.percent || lastStatus!=b.status) {
                    char message[128];snprintf(message,sizeof(message),"PRO X TKL: %d%%, %s, transport %s",b.percent,b.charging?"charging":b.full?"full":"discharging",b.transport);log_message(message);
                }
                last=b.percent;lastStatus=b.status;unavailableLogged=false;
            }
        } else {
            if(source){release(source);source=NULL;}
            if(!unavailableLogged)log_message("Keyboard unavailable or battery read failed; published entry removed.");
            unavailableLogged=true;last=-1;
        }
        poll_finished(&schedule,CFAbsoluteTimeGetCurrent(),available);
        sleep(1);
    }
    if(source)release(source);
    log_message("Stopped; published battery entry removed.");
    dlclose(lib);close(lock);return 0;
}
