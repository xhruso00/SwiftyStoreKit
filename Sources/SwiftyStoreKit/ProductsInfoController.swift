//
// ProductsInfoController.swift
// SwiftyStoreKit
//
// Copyright (c) 2015 Andrea Bizzotto (bizz84@gmail.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import StoreKit

protocol InAppProductRequestBuilder: AnyObject {
    func request(productIds: Set<String>, callback: @escaping InAppProductRequestCallback) -> InAppProductRequest
}

class InAppProductQueryRequestBuilder: InAppProductRequestBuilder {
    
    func request(productIds: Set<String>, callback: @escaping InAppProductRequestCallback) -> InAppProductRequest {
        return InAppProductQueryRequest(productIds: productIds, callback: callback)
    }
}

class ProductsInfoController: NSObject {

    struct InAppProductQuery {
        let request: InAppProductRequest
        var completionHandlers: [InAppProductRequestCallback]
    }
    
    let inAppProductRequestBuilder: InAppProductRequestBuilder
    init(inAppProductRequestBuilder: InAppProductRequestBuilder = InAppProductQueryRequestBuilder()) {
        self.inAppProductRequestBuilder = inAppProductRequestBuilder
    }
    
    // As we can have multiple inflight requests, we store them in a dictionary by product ids
    private var inflightRequestsStorage: [Set<String>: InAppProductQuery] = [:]
    private let requestsQueue = DispatchQueue(label: "inflightRequestsQueue")
    private var inflightRequests: [Set<String>: InAppProductQuery] = [:]

    @discardableResult
    func retrieveProductsInfo(_ productIds: Set<String>, completion: @escaping (RetrieveResults) -> Void) -> InAppProductRequest {

        var requestToReturn: InAppProductRequest!
        var handlersToCallIfCompleted: [InAppProductRequestCallback]?
        var resultsIfCompleted: RetrieveResults?

        // Use queue.sync to ensure all access to inflightRequests is serialized
        requestsQueue.sync {
            // Check if a request already exists
            if var query = self.inflightRequests[productIds] {
                // --- Request Exists ---
                
                // Append the new completion handler
                query.completionHandlers.append(completion)
                self.inflightRequests[productIds] = query // Update the dictionary
                requestToReturn = query.request

                // If the existing request is already completed, capture its results
                // and handlers to call them *outside* this sync block.
                if query.request.hasCompleted, let results = query.request.cachedResults {
                    handlersToCallIfCompleted = query.completionHandlers
                    resultsIfCompleted = results
                }
                
            } else {
                // --- Request Does NOT Exist ---

                // Create the actual SKProductsRequest via the builder
                let request = self.inAppProductRequestBuilder.request(productIds: productIds) { results in
                    
                    var handlersToCall: [InAppProductRequestCallback]?
                    
                    // Synchronize access within the callback
                    self.requestsQueue.sync {
                        // Retrieve the handlers and remove the request from inflight
                        handlersToCall = self.inflightRequests[productIds]?.completionHandlers
                        self.inflightRequests[productIds] = nil
                    }
                    
                    // Call all completion handlers asynchronously on the main thread
                    DispatchQueue.main.async {
                        handlersToCall?.forEach { $0(results) }
                    }
                }
                
                // Store the new query in the dictionary (This was the crash site, now safe)
                self.inflightRequests[productIds] = InAppProductQuery(request: request, completionHandlers: [completion])
                request.start() // Start the StoreKit request
                requestToReturn = request
            }
        }

        // If we found an already-completed request earlier, call its handlers now.
        // This runs outside the sync block and asynchronously.
        if let handlers = handlersToCallIfCompleted, let results = resultsIfCompleted {
            DispatchQueue.main.async {
                handlers.forEach { $0(results) }
            }
        }

        // Return the request (either existing or new)
        return requestToReturn
    }
}
