/****************************************************************************************
 * D timeout helper library. Timeouts can be registered, stored and fired. Supports
 * various forms of event clocks through the use of external polling, to minimize
 * syscalls.
 *
 *   Copyright: Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
 *
 *   License:
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 ***************************************************************************************/
module lib.timeout;

private import tango.util.container.more.Heap;
private import tango.time.Clock;
private import tango.time.Time;

class TimeoutQueue {
    alias void delegate(Time deadline, Time now) Callback;
    alias TimeoutEvent EventId;
private:
    struct TimeoutEvent {
        Time at;
        Callback cb;
        int opCmp(TimeoutEvent other) {
            return this.at.opCmp(other.at);
        }
    }
    Heap!(TimeoutEvent, true) _queue;
public:
    /************************************************************************************
     * Register a callback with a specified absolute deadline.
     ***********************************************************************************/
    EventId registerAt(Time t, Callback c) {
        auto event = TimeoutEvent(t,c);
        _queue.push(event);
        return event;
    }

    /************************************************************************************
     * Register a callback with a specified deadline relative to UTC.now
     ***********************************************************************************/
    EventId registerIn(TimeSpan s, Callback c) {
        return registerAt(Clock.now + s, c);
    }

    /************************************************************************************
     * Abort a previously registered event
     ***********************************************************************************/
    void abort(EventId event) {
        _queue.remove(event);
    }

    /************************************************************************************
     * Clear all timeouts in queue
     ***********************************************************************************/
    void clear() {
        _queue.clear();
    }

    /************************************************************************************
     * Figure next DeadLine, which is either time to the first timeout, or TimeSpan.max
     ***********************************************************************************/
    Time nextDeadline() {
        return _queue.size ? _queue.peek.at : Time.max;
    }

    /************************************************************************************
     * Fire all timeouts with passed deadline
     * Params:
     *     now =     [optional] The current time. Defaults to UTC.now.
     ***********************************************************************************/
    void emit() {
        emit(Clock.now);
    }
    /// ditto
    void emit(Time now) {
        while (_queue.size && (now >= _queue.peek.at)) {
            auto event = _queue.pop;
            event.cb(event.at, now);
        }
    }
}