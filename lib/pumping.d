/****************************************************************************************
 * Pumping micro-framework for select-driven asynchronous processing.
 *
 * Copyright (C) 2010 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>
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
 ****************************************************************************************/

public import tango.io.model.IConduit;
public import tango.io.selector.model.ISelector;
import tango.io.selector.Selector;
import tango.time.Clock;

/****************************************************************************************
 * Processors are the work-horses of the Pump framework. Each processor tracks
 * their own conduits and timeouts.
 ***************************************************************************************/
interface IProcessor {
    /************************************************************************************
     * Which Conduits can trigger events for this IProcessor?
     ***********************************************************************************/
    ISelectable[] conduits();

    /************************************************************************************
     * Process an event from the pump
     ***********************************************************************************/
    void process(ref SelectionKey cause);

    /************************************************************************************
     * When does this Processor need to process it's next timeout?
     ***********************************************************************************/
    Time nextDeadline();

    /************************************************************************************
     * Let the processor process all it's timeouts expected to happen until now.
     ***********************************************************************************/
    void processTimeouts(Time now);
}

/****************************************************************************************
 * Pump is the core of the Pump framework. The pump manages all the Processors,
 * selects among incoming events, and triggers process-events.
 ***************************************************************************************/
class Pump {
private:
    ISelector selector;
    IProcessor[] processors;
public:
    /************************************************************************************
     * Create a Pump with a possible initial list of processors
     ***********************************************************************************/
    this(IProcessor[] processors=[]) {
        selector = new Selector;
        selector.open(processors.length, processors.length * 2);
        foreach (p; processors)
            registerProcessor(p);
    }

    /************************************************************************************
     * Check if processor is registered in this pump
     ***********************************************************************************/
    bool has(IProcessor p) {
        foreach (x; processors) {
            if (x is p)
                return true;
        }
        return false;
    }

    /************************************************************************************
     * Register a conduit to a processor. The Processor may or may not be registered in
     * this pump before.
     ***********************************************************************************/
    void registerConduit(ISelectable c, IProcessor p) {
        if (!has(p))
            processors ~= p;
        selector.register(c, Event.Read, cast(Object)p);
    }

    /************************************************************************************
     * Unregister a conduit from this processor.
     ***********************************************************************************/
    void unregisterConduit(ISelectable c) {
        selector.unregister(c);
    }

    /************************************************************************************
     * Register an IProcessor in this pump, including all it's conduits.
     ***********************************************************************************/
    void registerProcessor(IProcessor p) {
        foreach (c; p.conduits)
            registerConduit(c, p);
    }

    /************************************************************************************
     * Shuts down this pump, stops the main loop and frees resources.
     ***********************************************************************************/
    void close() {
        selector.close;
        selector = null;
    }

    /************************************************************************************
     * Run until closed
     ***********************************************************************************/
    void run() {
        while (selector) {
            Time nextDeadline = Time.max;
            foreach (p; processors) {
                auto t = p.nextDeadline;
                if (t < nextDeadline)
                    nextDeadline = t;
            }
            ISelectable[] toRemove;
            if (selector.select(nextDeadline-Clock.now)>0) {
                foreach (SelectionKey key; selector.selectedSet())
                {
                    auto processor = cast(IProcessor)key.attachment;
                    processor.process(key);
                    if (key.isError() || key.isHangup() || key.isInvalidHandle()) {
                        toRemove ~= key.conduit; // Delayed removal to not break traversal
                    }
                }
                foreach (c; toRemove) unregisterConduit(c);
            }
            auto now = Clock.now;
            foreach (p; processors)
                p.processTimeouts(now);
        }
    }
}