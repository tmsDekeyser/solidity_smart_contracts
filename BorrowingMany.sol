// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

contract BorrowingMany {
    //State variables
    
    address payable private owner;
    
    uint public maxLoan;
    uint16 public interestX1000;
    uint public paybackTime;
    
    address[] proposedNotAccepted; 
    
    enum LoanState {
        NoLoan,
        BeforeLoan,
        LoanStarted
    }
    
    struct LoanDetails {
        address payable borrower;
        uint amountProposed;
        uint amountDue;
        uint endTime;
        LoanState loanState;
        bool earlyPay;
        uint key;
    }
    
    mapping(address => LoanDetails) public ledger;
    
    enum ContractState {
        Open,
        Paused
    }
    
    ContractState public contractState;
    
    // Events
    
    event LoanProposal(address _borrower, uint _amount);
    event LoanGranted(address _borrower, uint _amount);
    event LoanRejected(address _borrower, uint _amount);
    event LoanPaidBack(address _borrower, bool early);
    event ReminderToPay(uint _amountDue, address _borrower);
    
    //Modifiers
    
    modifier onlyOwner () {
        require(msg.sender == owner, "You are not the owner");
        _;
    }
    
    modifier onlyPaused() {
        require(contractState == ContractState.Paused, "Please pause the contract before making these changes");
        _;
    }
    
    modifier onlyOpen() {
        require(contractState == ContractState.Open, "These actions can only be taken when the owner has opened up to contract") ;
        _;
    }
    
    // Constructor + update functions
    constructor(uint16 _interest, uint _paybackTime, uint _maxLoan) {
        owner = payable(msg.sender);
        maxLoan = _maxLoan;
        interestX1000 = _interest;
        paybackTime = _paybackTime;
        contractState = ContractState.Paused;
    }
    
    function updateInterest(uint16 _interest) public onlyOwner onlyPaused {
        interestX1000 = _interest;
    }
    
    function updateMaxLoan(uint _maxLoan) public onlyOwner onlyPaused {
        maxLoan = _maxLoan;
    }
    
    function updatePaybackTime(uint _paybackTime) public onlyOwner onlyPaused {
        paybackTime = _paybackTime;
    }
    
    // Helper function
    
    function calculateAmountDue(uint _amount, bool _earlyPayDiscount) public view returns(uint) {
        if (_earlyPayDiscount) {
            
            return ((100000 + interestX1000/10 * 9)*_amount/100000);
        } else {
            return (100000 + interestX1000)*_amount/100000;
        }
    }
    
    function remove(uint index) internal {
        require(index < proposedNotAccepted.length, "There is no element at this index");
        address lastElement = proposedNotAccepted[proposedNotAccepted.length - 1];
        ledger[lastElement].key = index;
        
        proposedNotAccepted[index] = lastElement;
        proposedNotAccepted.pop();
    }
    
    function getProposedNotAccepted( uint index) public view returns (address) {
        return proposedNotAccepted[index];
    }
    
    //Borrowing functions
    
    function loanProposal(uint _amount) public onlyOpen {
        require(msg.sender != owner, "You cannot be lender and borrower");
        require(ledger[msg.sender].amountDue == 0, "Please pay off outstanding loan first");
        require(_amount <= maxLoan, "The amount exceeds the maximum amount available for borrowing");
        
        bool proposalPending = ledger[msg.sender].amountProposed > 0; 
        
        LoanDetails memory proposal;
        proposal.borrower = payable(msg.sender);
        proposal.amountProposed = _amount;
        if (_amount == 0) {
            proposal.loanState = LoanState.NoLoan;
        } else {
            proposal.loanState = LoanState.BeforeLoan;
        }
        proposal.earlyPay = ledger[msg.sender].earlyPay;
        
        if (!proposalPending) {
            proposal.key = proposedNotAccepted.length;
            proposedNotAccepted.push(msg.sender);
        } else {
            uint _key = ledger[msg.sender].key;
            proposal.key = _key;
            proposedNotAccepted[_key] = msg.sender;
        }
       
        
        ledger[msg.sender] = proposal;
        
        emit LoanProposal(msg.sender, _amount);
    }
    
    function initiateLoan(address _borrower) public payable onlyOwner onlyOpen {
        uint _amount = ledger[_borrower].amountProposed;
        address payable _to = ledger[_borrower].borrower; 
        
        _to.transfer(_amount);
        
        remove(ledger[_borrower].key);
        
        LoanDetails memory loan;
        loan.borrower = _to;
        loan.amountProposed = 0;
        loan.amountDue = calculateAmountDue(_amount, ledger[_borrower].earlyPay);
        loan.endTime = block.timestamp + paybackTime;
        loan.loanState = LoanState.LoanStarted;
        loan.earlyPay = false;
        loan.key = 0;
        
        ledger[_borrower] = loan;
            
        emit LoanGranted(_borrower, _amount);
        
    }
    
    function rejectLoan(address _borrower) public onlyOwner onlyOpen {
        emit LoanRejected(_borrower, ledger[_borrower].amountProposed);
        
        remove(ledger[_borrower].key);

        
        ledger[_borrower].amountProposed = 0;
        ledger[_borrower].loanState = LoanState.NoLoan;
    }
    
    function rejectAllProposedLoans() public onlyOwner {
        uint arrayLength = proposedNotAccepted.length;
        
        for (uint i = 0; i<arrayLength; i++) {
            rejectLoan(proposedNotAccepted[0]);
        }
    }
    
    function payback() public payable {
        uint _amountDue = ledger[msg.sender].amountDue;
        require(_amountDue == msg.value, "This is not the amount you owe, please enter correct amount");
        
        LoanDetails memory paidLoan;
        paidLoan.borrower = payable(msg.sender);
        paidLoan.amountDue = 0;
        paidLoan.endTime = 0;
        paidLoan.loanState = LoanState.NoLoan;
            
        if (block.timestamp < ledger[msg.sender].endTime) {
            paidLoan.earlyPay = true;
        }
        
        ledger[msg.sender] = paidLoan;
        
        owner.transfer(msg.value);
            
        emit LoanPaidBack(msg.sender, ledger[msg.sender].earlyPay); //Lender can decide to handle this event in application to give some reward for paying early.
        
    }
    
    function sendReminder(address _borrower) public onlyOwner {
        require(ledger[_borrower].loanState == LoanState.LoanStarted, "No Loan is active");
        require(block.timestamp > ledger[_borrower].endTime, "The due date for the loan has not yet been reached");
        
        emit ReminderToPay(ledger[_borrower].amountDue, _borrower);
    }
    
    // Owner control functions
    
    function pauseUnpause() public onlyOwner {
        if (contractState == ContractState.Paused) {
            contractState = ContractState.Open;
        } else {
            rejectAllProposedLoans();
            contractState = ContractState.Paused;
        }
    }
    
    function withdraw() public onlyOwner {
        owner.transfer(address(this).balance);
    }
    
    receive() external payable {
        
    }
}
