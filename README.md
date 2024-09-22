## ProxiRun: Decentralized Marketplace for Compute on Aptos
ProxiRun is a decentralized marketplace for requesting compute tasks on the Aptos blockchain. Users can post work requests, and workers bid on these requests. The contract manages the auction, selects the lowest bid, and handles payment for the work. The system relies on events emitted by the contract to orchestrate communication between users, workers, and the marketplace.

### Features
- Work Request Auction: Users submit a work request with a maximum price they are willing to pay. The system automatically runs an auction where workers can bid on the job, offering a price for their services.
- Bid Management: Workers submit bids with a price they are willing to work for. The auction remains open for a predefined duration, after which the lowest bid is chosen as the winner.
- Auction Finalization: Once the auction ends, the admin finalizes it, selecting the lowest bid or declaring the auction unsuccessful if no bids were submitted.
- Commitment and Payment: Once the work is completed by the selected worker, the contract verifies the completion. Funds are then released to the worker, and any difference between the maximum price and the winning bid is refunded to the requester.

### Event-Driven: Key processes in the system are driven by events that notify the relevant parties:
- OnNewWorkRequest: Triggered when a new work request is created.
- OnNewWorkRequestBid: Emitted when a worker places a bid.
- OnBidWon: Triggered when an auction ends with a winning bid.
- OnWorkRequestCompleted: Emitted when the work has been completed and verified.
- OnAuctionFailure: Triggered when an auction ends without a valid bid.

### Key Components
- Auction: Managed through the AuctionTable, which tracks active auctions, bids, and the status of each work request.
- User Balances: Tracked using UserBalanceTable, which ensures that user deposits are correctly handled and funds are locked until work is completed.
- Admin Role: The admin oversees the finalization of auctions and ensures that the process runs smoothly by invoking key functions like finalizing auctions and committing to the results.

### Smart Contract Functions

#### Entrypoints
- Creating a Work Request: Users can submit a work request by specifying the maximum price they are willing to pay.
- Bidding on Work: Workers can bid on active work requests, submitting a price lower than or equal to the maximum price.
- Finalize Auction: Admins can finalize an auction once its time has expired, selecting the winning bid or refunding the user if no bids were received.
- Commit: Once the worker has completed the task, the admin finalizes the transaction by releasing funds and updating the contract's state.

#### Views
- Get Work Request: Retrieve details of a specific work request.
- Get User Balance: View the balance of a particular user.
- Get Bids: Fetch all bids associated with a specific work request.
- Get Auction: Fetch the full auction entry for a specific request.