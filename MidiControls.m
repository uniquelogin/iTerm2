#import <dispatch/dispatch.h>
#import <CoreMIDI/CoreMIDI.h>
#import "iTermController.h"
#import "PTYSession.h"
#import "PTYTab.h"
#import "PseudoTerminal.h"
#import "MidiControls.h"

void iTermMIDINotifyProc(const MIDINotification *message, void *refCon);
void iTermMIDIReadProc(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon);

// Assume we have a 16-pad Yamaha/Steinberg CMC-PD controller that is configured with 16 consecutive notes [C2, D#3]

static NSString* MIDI_NOTES_PORT_NAME = @"Steinberg CMC-PD Port1";
static NSString* MIDI_CC_PORT_NAME = @"Steinberg CMC-PD Port2";
static const int MIDI_NUM_PADS = 16;
static const int MIDI_FIRST_NOTE = 36;
static const int MIDI_MIN_VELOCITY = 32;

int MapIdToNote(int windowId);
int MapIdToNote(int windowId)
{
    if (windowId >= 0 && windowId < MIDI_NUM_PADS) {
        return windowId + MIDI_FIRST_NOTE;
    }
    return -1;
}

int MapNoteToId(int noteId);
int MapNoteToId(int noteId)
{
    if (noteId >= MIDI_FIRST_NOTE && noteId < MIDI_FIRST_NOTE + MIDI_NUM_PADS) {
        return noteId - MIDI_FIRST_NOTE;
    }
    return -1;
}

NSString *GetMidiDisplayName(MIDIObjectRef object);

void HandleMidiMessage(const Byte** data, const Byte* end, int* noteOn, int* ccChange);

@implementation iTermMidiControls
{
    // How many notes to extinguish before the next tick
    int prevSessions;

    MIDIEndpointRef midiDest;
    MIDIEndpointRef midiSrc;
    MIDIEndpointRef midiCCSrc;

    MIDIClientRef midiClientRef;

    MIDIPortRef midiOutPortRef;
    MIDIPortRef midiInPortRef;
    MIDIPortRef midiCCPortRef;

    int scheduledTabIndex; // -1 if no tab/session switch is scheduled
    int scheduledCcChange; // 0 if no change pending
}

- (void)scheduleTabSwitch:(int)index
{
    @synchronized(self) {
        scheduledTabIndex = index;
    }
}

- (int)getScheduledTabSwitch
{
    @synchronized(self) {
        int result = scheduledTabIndex;
        scheduledTabIndex = -1;
        return result;
    }
}

- (void)scheduleCcChange:(int)delta
{
    @synchronized(self) {
        scheduledCcChange = delta; //TODO: += ?
    }
}

- (int)getScheduledCcChange
{
    @synchronized(self) {
        int result = scheduledCcChange;
        scheduledCcChange = 0;
        return result;
    }
}

- (MIDIEndpointRef)findMidiEndpoint:(NSString *)portName isSource:(BOOL)isSource
{
    // With thanks to http://xmidi.com/how-to-access-midi-devices-with-coremidi/
    ItemCount destCount = isSource ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations();
    for (ItemCount i = 0 ; i < destCount ; ++i) {
        MIDIEndpointRef candidate = isSource ? MIDIGetSource(i) : MIDIGetDestination(i);
        if (candidate == 0) {
            continue;
        }
        NSString* displayName = GetMidiDisplayName(candidate);
        if ([displayName isEqualToString:portName]) {
            return candidate;
        }
    }
    return NULL;
}

- (void)handleMidiInput:(id)dummy
{
    int tabToSwitch = [self getScheduledTabSwitch];
    if (tabToSwitch >= 0) {
        int nTerminals = [[iTermController sharedInstance] numberOfTerminals];
        int idx = 0;
        for (int i = 0; i < nTerminals; ++i) {
            PseudoTerminal* pt = [[iTermController sharedInstance] terminalAtIndex:i];

            NSArray* allPtSessions = [pt allSessions];
            for (PTYSession* sess in allPtSessions) {
                if (idx == tabToSwitch) {
                    [sess reveal];
                    [sess setFocused:YES];
                    return;
                }
                ++idx;
            }
        }
    }
    int ccDelta = [self getScheduledCcChange];
    if (ccDelta) {
        PseudoTerminal* pt = [[iTermController sharedInstance] currentTerminal];
        if (pt != nil) {
            PTYSession* session = [pt currentSession];
            if (session != nil) {
                float trans = session.transparency;
                trans -= (ccDelta * .025f);
                if (trans < .0f) {
                    trans = .0f;
                }
                else if (trans > 0.9f) {
                    trans = 0.9f;
                }
                session.transparency = trans;
            }
        }
    }
}

- (void)onTimer:(id)dummy
{
    NSMutableArray* tabs = [[NSMutableArray alloc] init];

    int activeTerminalSessionsStart = 0;
    int activeTerminalSessionsEnd = 0;

    int nTerminals = [[iTermController sharedInstance] numberOfTerminals];
    for (int i = 0; i < nTerminals; ++i) {
        PseudoTerminal* pt = [[iTermController sharedInstance] terminalAtIndex:i];
        if (pt == [[iTermController sharedInstance] currentTerminal]) {
            activeTerminalSessionsStart = tabs.count;
        }

        NSArray* allPtSessions = [pt allSessions];
        for (PTYSession* sess in allPtSessions) {
            [tabs addObject:sess];
        }

        if (pt == [[iTermController sharedInstance] currentTerminal]) {
            activeTerminalSessionsEnd = tabs.count;
        }
    }

    MIDIPacketList packetList;
    MIDIPacket* packet = MIDIPacketListInit(&packetList);
    int dataSize = 0;
    for (int i = 0; i < prevSessions; ++i) {
        packet->data[dataSize++] = 0x80; // note off, channel 0
        packet->data[dataSize++] = MapIdToNote(i);
        packet->data[dataSize++] = 0x7F;
    }
    prevSessions = [tabs count];
    int tabIdx = 0;
    for (PTYSession* sess in tabs) {
        BOOL newOutput = sess.newOutput;
        if (sess.liveSession != nil) {
            newOutput = sess.liveSession.newOutput;
        }
        int velocity = 32; // green
        if ([sess.tab isForegroundTab] && tabIdx >= activeTerminalSessionsStart && tabIdx < activeTerminalSessionsEnd) {
            velocity = 64;
        }
        else if (newOutput) {
            velocity = 96; // red
        }

        packet->data[dataSize++] = 0x90; // note on, channel 0
        packet->data[dataSize++] = MapIdToNote(tabIdx);
        packet->data[dataSize++] = velocity; // green
        ++tabIdx;
    }

    packet->length = dataSize;
    packet->timeStamp = 0;
    packetList.numPackets = 1;

    if (0 != MIDISend(midiOutPortRef, midiDest, &packetList)) {
        NSLog(@"MIDI send failed!");
    }
}

- (id)init
{
    self = [super init];
    if (self == nil) {
        return nil;
    }

    //TODO: initialize MIDI on a main run loop
    //TODO: add an "initialized" flag
    //TODO: send Note Off for all pads, or just an All Notes Off message, if supported
    //TODO: dispose of endpoints created

    prevSessions = 0;

    scheduledCcChange = 0;
    scheduledTabIndex = -1;

    midiDest = 0;
    midiSrc = 0;
    midiCCSrc = 0;

    midiClientRef = NULL;
    midiOutPortRef = NULL;
    midiInPortRef = NULL;
    midiCCPortRef = NULL;

    midiDest = [self findMidiEndpoint:MIDI_NOTES_PORT_NAME isSource:NO];
    if (!midiDest) {
        NSLog(@"MIDI destination not found");
        return nil;
    }

    midiSrc = [self findMidiEndpoint:MIDI_NOTES_PORT_NAME isSource:YES];
    if (!midiSrc) {
        NSLog(@"MIDI source not found");
        return nil;
    }

    midiCCSrc = [self findMidiEndpoint:MIDI_CC_PORT_NAME isSource:YES];
    if (!midiCCSrc) {
        NSLog(@"MIDI CC source not found");
    }

    if (0 != MIDIClientCreate((CFStringRef)@"iTermMidiClient", iTermMIDINotifyProc, self, &midiClientRef)) {
        NSLog(@"Error creating MIDI client");
        return nil;
    }

    if (0 != MIDIOutputPortCreate(midiClientRef, (CFStringRef)@"iTermMidiOut", &midiOutPortRef)) {
        NSLog(@"Error creating MIDI port");
        return nil;
    }

    if (0 != MIDIInputPortCreate(midiClientRef, (CFStringRef)@"iTermMidiIn", iTermMIDIReadProc, self, &midiInPortRef)) {
        NSLog(@"Error creating input MIDI port");
        return nil;
    }

    if (0 != MIDIPortConnectSource(midiInPortRef, midiSrc, nil)) {
        NSLog(@"Failed to connect input port to an input MIDI source");
        return nil;
    }

    if (0 != MIDIInputPortCreate(midiClientRef, (CFStringRef)@"iTermMidiCCIn", iTermMIDIReadProc, self, &midiCCPortRef)) {
        NSLog(@"Error creating input MIDI port");
    }

    if (midiCCPortRef && 0 != MIDIPortConnectSource(midiCCPortRef, midiCCSrc, nil)) {
        NSLog(@"Failed to connect input port to an input MIDI source");
    }

    return self;
}

void iTermMIDIReadProc (const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon)
{
    iTermMidiControls* controls = (iTermMidiControls*)readProcRefCon;
    const MIDIPacket* packet = pktlist->packet;
    int lastNoteOn = -1;
    int ccChangeAcc = 0;
    for (UInt32 i = 0; i < pktlist->numPackets; ++i) {
        const Byte* data = packet->data;
        const Byte* end = data + packet->length;
        while (data < end) {
            int noteOn = -1;
            int ccChange = 0;
            HandleMidiMessage(&data, end, &noteOn, &ccChange);
            if (noteOn >= 0) {
                lastNoteOn = noteOn;
            }
            ccChangeAcc += ccChange;
        }
        packet = MIDIPacketNext(packet);
    }

    if (lastNoteOn >= 0) {
        [controls scheduleTabSwitch:MapNoteToId(lastNoteOn)];
    }

    if (ccChangeAcc) {
        [controls scheduleCcChange:ccChangeAcc];
    }

    [controls performSelectorOnMainThread:@selector(handleMidiInput:) withObject:nil waitUntilDone:NO];
}

void iTermMIDINotifyProc(const MIDINotification *message, void *refCon)
{
    NSLog(@"Received a MIDI notification message!");
    /*TODO: when a configuration change is detected:
        - drop the "initialized" flag
        - schedule a reinitialization
    */
}

NSString *GetMidiDisplayName(MIDIObjectRef object)
{
    CFStringRef name = nil;
    if (noErr != MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name))
        return nil;
    return (NSString *)name;
}

void HandleMidiMessage(const Byte** data, const Byte* end, int* noteOn, int* ccChange)
{
    const Byte* ptr = *data;
    const Byte msg = *ptr;
    ++ptr;
    *noteOn = -1;
    *ccChange = 0;

    if ((msg & 0xF0) == 0x90) { // note on
        // fun fact: CMC-PD sends 0-velocity note on instead of a note off
        int note = ptr[0];
        int vel = ptr[1];
        ptr += 2;
        *noteOn = (vel >= MIDI_MIN_VELOCITY) ? note : -1;
    }
    else if ((msg & 0xF0) == 0x80) { // note off
        ptr += 2;
    }
    else if ((msg & 0xF0) == 0xA0) { // afertouch poly
        ptr += 2;
    }
    else if ((msg & 0xF0) == 0xB0) { // control change; CMC-PD-specific processing
        int ctrlr = ptr[0];
        int value = ptr[1];
        if (value >= 32) {
            value = -(value & 0x3F);
        }
        if (ctrlr == 60) {
            *ccChange = value;
        }
        ptr += 2;
    }
    else if ((msg & 0xF0) == 0xC0) { // program change
        ptr += 2;
    }
    else if ((msg & 0xF0) == 0xD0) { // aftertouch channel
        ptr += 2;
    }
    else if ((msg & 0xF0) == 0xE0) { // pitch bend
        ptr += 2;
    }
    else if (msg == 0xF0) { // 11110000: system extended message
        while (ptr < end && (*ptr & 0x80) == 0) { // end marker is a byte with MSB set
            ++ptr;
        }
        ++ptr;
    }
    else if (msg == 0xF1) { // 1111xxxx: system common messages
        ptr += 1;
    }
    else if (msg == 0xF2) {
        ptr += 1;
    }
    else if (msg == 0xF3) {
        ptr += 1;
    }
    // other messages do not have parameters

    *data = ptr;
}

@end

