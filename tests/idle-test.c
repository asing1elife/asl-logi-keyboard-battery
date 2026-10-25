// Deterministic activity transitions with no real peripheral I/O.
#include <IOKit/hid/IOHIDManager.h>
#include <assert.h>
static int writes,enumerations;
static IOReturn fake_set_report(IOHIDDeviceRef device,IOHIDReportType type,CFIndex reportID,const uint8_t *report,CFIndex length) {
    (void)device;(void)type;(void)reportID;(void)report;(void)length;
    writes++;return kIOReturnError;
}
static IOHIDManagerRef fake_create(CFAllocatorRef allocator,IOOptionBits options) {
    (void)allocator;(void)options;enumerations++;
    assert(!"Idle/unknown activity must not enumerate peripheral interfaces");
    return NULL;
}
#define IOHIDDeviceSetReport fake_set_report
#define IOHIDManagerCreate fake_create
#define main bridge_main
#include "../src/keyboard-battery.c"
#undef main
#undef IOHIDDeviceSetReport
#undef IOHIDManagerCreate
static double simulated_idle;
static double fake_idle(void){return simulated_idle;}
int main(void) {
    idle_reader=fake_idle;
    Channel channel={0};Battery battery={0};
    simulated_idle=30;
    assert(!scan(&battery));assert(!request(&channel,0,0x0a,0x10,0x04));
    assert(writes==0 && enumerations==0 && query_interrupted);
    query_interrupted=false;simulated_idle=-1;
    assert(!scan(&battery));assert(!request(&channel,0,0x0a,0x10,0x04));
    assert(writes==0 && enumerations==0 && query_interrupted);
    simulated_idle=0;query_interrupted=false;
    assert(!request(&channel,0,0x0a,0x10,0x04)); // fake I/O failure
    assert(writes==1 && !query_interrupted);
    simulated_idle=30;
    assert(!request(&channel,6,0x1a,0,0)); // idle between two reports
    assert(writes==1 && query_interrupted);
    PollSchedule s={.previous=-1,.due=0};
    assert(!poll_due(&s,IDLE,0)); // service starts idle
    assert(!poll_due(&s,IDLE,3600)); // no retry even after an hour
    assert(poll_due(&s,ACTIVE,3601)); // input resumes
    poll_finished(&s,3601,true);
    assert(!poll_due(&s,ACTIVE,3610));
    assert(!poll_due(&s,IDLE,3631));
    assert(poll_due(&s,ACTIVE,3632)); // resume before normal deadline
    poll_finished(&s,3632,false);
    assert(!poll_due(&s,ACTIVE,3646));assert(poll_due(&s,ACTIVE,3647));
    poll_finished(&s,3647,true);
    assert(!poll_due(&s,ACTIVITY_UNKNOWN,3648));
    assert(!poll_due(&s,ACTIVITY_UNKNOWN,10000));
    assert(poll_due(&s,ACTIVE,10001));
    poll_finished(&s,10001,true);
    assert(!poll_due(&s,ACTIVE,10060));assert(poll_due(&s,ACTIVE,10061));
    puts("PASS: idle/unknown activity blocks enumeration and HID writes; resume refreshes immediately; active polling and retry intervals preserved.");
    return 0;
}
