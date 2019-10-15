//
//  FeedlyCompoundOperation.swift
//  Account
//
//  Created by Kiel Gillard on 10/10/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

import Foundation

/// An operation with a queue of its own.
final class FeedlyCompoundOperation: FeedlyOperation {
	private let operationQueue = OperationQueue()
	private let operations: [Operation]
	
	init(operations: [Operation]) {
		assert(!operations.isEmpty)
		self.operations = operations
	}
	
	convenience init(operationsBlock: () -> ([Operation])) {
		let operations = operationsBlock()
		self.init(operations: operations)
	}
	
	override func main() {
		let finishOperation = BlockOperation { [weak self] in
			self?.didFinish()
		}
		
		for operation in operations {
			finishOperation.addDependency(operation)
		}
		
		var operationsWithFinish = operations
		operationsWithFinish.append(finishOperation)
		
		operationQueue.addOperations(operationsWithFinish, waitUntilFinished: false)
	}
	
	override func cancel() {
		operationQueue.cancelAllOperations()
		super.cancel()
	}
}
